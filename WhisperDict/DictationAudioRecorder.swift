import AVFoundation
import Foundation
import WhisperKit

final class DictationAudioRecorder {
    enum RecorderError: LocalizedError {
        case noInput
        case listeningWindowInactive
        var errorDescription: String? {
            switch self {
            case .noInput: "No microphone input is available."
            case .listeningWindowInactive: "Background listening stopped. Open WhisperDict once to start it again."
            }
        }
    }

    /// What Whisper consumes: 16 kHz mono float. Converting inside the tap
    /// means the samples are ready the moment recording stops — nothing is
    /// written to disk while capturing, and there is no decode-and-resample
    /// pass standing between the user finishing and seeing text.
    private static let whisperFormat = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!

    /// Six minutes of samples (~23 MB). Recording is capped below this, so
    /// hitting it means something failed to stop; dropping the tail is far
    /// better than growing without bound.
    private static let maximumSampleCount = 16_000 * 60 * 6

    var onLevel: (@Sendable (Float) -> Void)?
    var onInterruption: (@Sendable () -> Void)?

    private let session = AVAudioSession.sharedInstance()
    private var engine: AVAudioEngine?
    private var observerTokens: [NSObjectProtocol] = []

    private let samplesLock = NSLock()
    private var samples: [Float] = []

    private(set) var isRecording = false

    /// False while a listening window owns the audio session: reconfiguring
    /// the category here would stop the keepalive and drop residency.
    var managesAudioSession = true

    /// A running engine whose input is already capturing. When present, the
    /// recorder only installs a tap on it — the one thing iOS allows from
    /// the background — instead of starting an engine of its own.
    var sharedEngine: (() -> AVAudioEngine?)?
    private var usesSharedEngine = false

    init() {
        let center = NotificationCenter.default
        observerTokens.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: session,
            queue: .main
        ) { [weak self] notification in
            guard
                let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                AVAudioSession.InterruptionType(rawValue: typeValue) == .began,
                self?.isRecording == true
            else { return }
            self?.onInterruption?()
        })
        observerTokens.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: session,
            queue: .main
        ) { [weak self] notification in
            guard
                let reasonValue = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                AVAudioSession.RouteChangeReason(rawValue: reasonValue) == .oldDeviceUnavailable,
                self?.isRecording == true
            else { return }
            self?.onInterruption?()
        })
    }

    deinit {
        observerTokens.forEach(NotificationCenter.default.removeObserver)
    }

    func start() throws {
        guard !isRecording else { return }
        let shared = managesAudioSession ? nil : sharedEngine?()
        if let shared {
            guard shared.isRunning else { throw RecorderError.listeningWindowInactive }
        } else if managesAudioSession {
            try session.setCategory(.record, mode: .measurement, options: [.allowBluetoothHFP])
            try session.setActive(true)
        }

        let engine = shared ?? AVAudioEngine()
        usesSharedEngine = shared != nil
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw RecorderError.noInput }

        // Built once per recording rather than per buffer: AVAudioConverter
        // carries resampler state, and rebuilding it every tap would both
        // cost more and click at the seams.
        var converter: AVAudioConverter?
        if format != Self.whisperFormat {
            guard let made = AVAudioConverter(from: format, to: Self.whisperFormat) else {
                throw RecorderError.noInput
            }
            converter = made
        }

        samplesLock.lock()
        samples.removeAll(keepingCapacity: true)
        samples.reserveCapacity(16_000 * 30)
        samplesLock.unlock()

        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            guard let converter else {
                self.append(buffer)
                return
            }
            guard let resampled = try? AudioProcessor.resampleBuffer(buffer, with: converter) else { return }
            self.append(resampled)
        }

        do {
            if !usesSharedEngine {
                engine.prepare()
                try engine.start()
            }
            self.engine = engine
            isRecording = true
        } catch {
            input.removeTap(onBus: 0)
            if managesAudioSession {
                try? session.setActive(false, options: .notifyOthersOnDeactivation)
            }
            throw error
        }
    }

    /// Returns the captured 16 kHz mono samples, or nil when nothing was
    /// captured. The buffer is handed over, not copied on both sides.
    func stop() -> [Float]? {
        guard isRecording else { return nil }
        engine?.inputNode.removeTap(onBus: 0)
        // A shared engine belongs to the listening window and keeps running.
        if !usesSharedEngine { engine?.stop() }
        engine = nil
        usesSharedEngine = false
        isRecording = false
        onLevel?(0)
        if managesAudioSession {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
        }

        samplesLock.lock()
        let captured = samples
        samples = []
        samplesLock.unlock()
        return captured.isEmpty ? nil : captured
    }

    private func append(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?.pointee else { return }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return }

        samplesLock.lock()
        if samples.count + count <= Self.maximumSampleCount {
            samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: count))
        }
        samplesLock.unlock()

        onLevel?(Self.normalizedLevel(channel, count: count))
    }

    private static func normalizedLevel(_ data: UnsafePointer<Float>, count: Int) -> Float {
        var sum: Float = 0
        for index in 0..<count {
            let sample = data[index]
            sum += sample * sample
        }
        let rms = sqrt(sum / Float(count))
        return min(max((20 * log10(max(rms, 0.000_001)) + 60) / 60, 0), 1)
    }
}
