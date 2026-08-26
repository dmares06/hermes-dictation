import AVFoundation
import Foundation

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

    var onLevel: (@Sendable (Float) -> Void)?
    var onInterruption: (@Sendable () -> Void)?

    private let session = AVAudioSession.sharedInstance()
    private var engine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var recordingURL: URL?
    private var observerTokens: [NSObjectProtocol] = []

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

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("whisperdict-\(UUID().uuidString).caf")
        let file = try AVAudioFile(forWriting: url, settings: format.settings)

        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            do {
                try self.audioFile?.write(from: buffer)
                self.onLevel?(Self.normalizedLevel(from: buffer))
            } catch {
                NSLog("WhisperDict audio write failed: \(error.localizedDescription)")
            }
        }

        do {
            self.audioFile = file
            recordingURL = url
            if !usesSharedEngine {
                engine.prepare()
                try engine.start()
            }
            self.engine = engine
            isRecording = true
        } catch {
            input.removeTap(onBus: 0)
            audioFile = nil
            recordingURL = nil
            if managesAudioSession {
                try? session.setActive(false, options: .notifyOthersOnDeactivation)
            }
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    func stop() -> URL? {
        guard isRecording else { return nil }
        engine?.inputNode.removeTap(onBus: 0)
        // A shared engine belongs to the listening window and keeps running.
        if !usesSharedEngine { engine?.stop() }
        engine = nil
        usesSharedEngine = false
        audioFile = nil
        isRecording = false
        onLevel?(0)
        if managesAudioSession {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
        }
        defer { recordingURL = nil }
        return recordingURL
    }

    private static func normalizedLevel(from buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?.pointee else { return 0 }
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return 0 }

        var sum: Float = 0
        for index in 0..<frameLength {
            let sample = data[index]
            sum += sample * sample
        }
        let rms = sqrt(sum / Float(frameLength))
        return min(max((20 * log10(max(rms, 0.000_001)) + 60) / 60, 0), 1)
    }
}
