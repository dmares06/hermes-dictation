import AVFoundation
import Foundation

/// Keeps the microphone capture running for the whole listening window.
///
/// iOS lets a backgrounded app *continue* an audio capture it began in the
/// foreground, but never *begin* one — starting an input engine from the
/// background fails with `kAudioUnitErr_CannotDoInCurrentContext`. So the
/// window opens the microphone while the app is visible and leaves it
/// running; a dictation only installs a tap on the already-running input.
/// The cost is the orange microphone indicator staying on for the window,
/// which is exactly what other dictation keyboards' "session" looks like.
final class ResidentAudioKeepalive {
    private let session = AVAudioSession.sharedInstance()
    private(set) var engine: AVAudioEngine?
    private var configurationObserver: NSObjectProtocol?

    /// Fired when the system rebuilt the audio graph (route change, sample
    /// rate change). Any tap on the old input is gone; the owner should treat
    /// an in-flight recording as interrupted.
    var onConfigurationChange: (() -> Void)?

    var isRunning: Bool { engine?.isRunning == true }

    func start() throws {
        guard !isRunning else { return }
        try session.setCategory(
            .playAndRecord,
            mode: .default,
            options: [.mixWithOthers, .allowBluetoothHFP, .defaultToSpeaker]
        )
        try session.setActive(true)
        try startEngine()
    }

    func stop() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        // Only release a session this engine holds. A stop that arrives after
        // someone else has taken the session — the agent's recorder, say —
        // must not deactivate it out from under them.
        guard let engine else { return }
        engine.stop()
        self.engine = nil
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Rebuilds the engine after an interruption or configuration change.
    func restart() throws {
        engine?.stop()
        engine = nil
        try session.setActive(true)
        try startEngine()
    }

    private func startEngine() throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw KeepaliveError.noInput }

        // The input has to be part of the rendering graph to keep capturing.
        // Routing it to a muted mixer keeps the graph live without monitoring
        // the microphone through the speaker.
        engine.connect(input, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 0
        engine.prepare()
        try engine.start()
        self.engine = engine

        if configurationObserver == nil {
            configurationObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let self, notification.object as? AVAudioEngine === self.engine else { return }
                self.onConfigurationChange?()
                try? self.restart()
            }
        }
    }

    enum KeepaliveError: LocalizedError {
        case noInput
        var errorDescription: String? { "No microphone input is available." }
    }
}
