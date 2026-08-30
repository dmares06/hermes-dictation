import AVFoundation

/// A soft, wordless tick while Hermes works on a live call.
///
/// The voice no longer speaks filler — no "let me check", no progress
/// lines — so a long tool run would otherwise be dead air, and dead air
/// on a call reads as a dropped line. The tick is the sign of life:
/// quiet, quick to tune out, and it says nothing about tools.
///
/// It never touches the audio session — WebRTC owns it during a call —
/// and only mixes its blip into whatever output is already routed.
@MainActor
final class ThinkingEarcon {
    /// Quick turns should pass in silence; only a wait long enough to
    /// feel like one earns a tick.
    static let firstTickDelay: TimeInterval = 2
    static let interval: TimeInterval = 2.5

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let buffer: AVAudioPCMBuffer?
    private var ticker: Task<Void, Never>?

    init() {
        buffer = Self.makeTickBuffer()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: buffer?.format)
    }

    func setActive(_ active: Bool) {
        if active { start() } else { stop() }
    }

    private func start() {
        guard ticker == nil else { return }
        ticker = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.firstTickDelay))
            while !Task.isCancelled {
                guard let self else { return }
                self.playTick()
                try? await Task.sleep(for: .seconds(Self.interval))
            }
        }
    }

    private func stop() {
        ticker?.cancel()
        ticker = nil
        player.stop()
        if engine.isRunning { engine.stop() }
    }

    private func playTick() {
        guard let buffer else { return }
        if !engine.isRunning {
            do { try engine.start() } catch {
                // No session to play into (the call is tearing down); the
                // next tick tries again, and stop() ends the attempts.
                AgentTurnLog.note("earcon engine failed: \(error.localizedDescription)")
                return
            }
        }
        if !player.isPlaying { player.play() }
        player.scheduleBuffer(buffer, at: nil)
    }

    /// One 70 ms sine blip with a fast exponential decay, well below
    /// speech volume: felt more than listened to.
    private static func makeTickBuffer() -> AVAudioPCMBuffer? {
        let sampleRate = 48_000.0
        let frequency = 950.0
        let amplitude: Float = 0.055
        let frames = AVAudioFrameCount(sampleRate * 0.07)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let samples = buffer.floatChannelData?[0]
        else { return nil }
        buffer.frameLength = frames
        for frame in 0..<Int(frames) {
            let time = Double(frame) / sampleRate
            let envelope = Float(exp(-time * 60))
            samples[frame] = amplitude * envelope * Float(sin(2 * .pi * frequency * time))
        }
        return buffer
    }
}
