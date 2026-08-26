import AVFoundation
import Foundation

/// Keeps the process alive in the background by rendering silence.
///
/// iOS only honours the `audio` background mode while audio is actually
/// flowing, so a resident listening window needs an engine running the whole
/// time. Silence through a player node costs little and, unlike holding the
/// microphone open, does not light the recording indicator between
/// dictations.
///
/// The category is `.playAndRecord` from the outset so a recording can start
/// later without reconfiguring — and thereby interrupting — the session.
final class ResidentAudioKeepalive {
    private let session = AVAudioSession.sharedInstance()
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?

    private(set) var isRunning = false

    func start() throws {
        guard !isRunning else { return }
        try session.setCategory(
            .playAndRecord,
            mode: .default,
            options: [.mixWithOthers, .allowBluetoothHFP, .defaultToSpeaker]
        )
        try session.setActive(true)

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)

        guard let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1),
              let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100)
        else { throw KeepaliveError.formatUnavailable }
        silence.frameLength = silence.frameCapacity
        engine.connect(player, to: engine.mainMixerNode, format: format)

        engine.prepare()
        try engine.start()
        player.scheduleBuffer(silence, at: nil, options: .loops)
        player.play()

        self.engine = engine
        self.player = player
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        player?.stop()
        engine?.stop()
        player = nil
        engine = nil
        isRunning = false
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
    }

    enum KeepaliveError: LocalizedError {
        case formatUnavailable
        var errorDescription: String? { "The audio engine could not be prepared." }
    }
}
