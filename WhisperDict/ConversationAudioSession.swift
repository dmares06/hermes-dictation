import AVFoundation
import Foundation

/// Holds the audio session for a whole spoken conversation, so locking the
/// phone does not end it.
///
/// The slower Hermes path used to reconfigure the session every turn:
/// `.record` to listen, `.playback` to reply, deactivated in between. On an
/// unlocked phone that is merely wasteful. Locked, it is fatal twice over —
/// iOS lets a backgrounded app *continue* a capture it began in the
/// foreground but never *begin* one, so the next turn's microphone never
/// opens; and a session that goes inactive with nothing playing lets the
/// app be suspended, which kills the turn in flight.
///
/// So the session is configured once, for the life of the conversation, and
/// a capture engine runs unbroken underneath it. The engine is what keeps
/// the app alive through the silent gaps while Hermes thinks, and what
/// every turn's recorder installs its tap on.
@MainActor
final class ConversationAudioSession {
    private let session = AVAudioSession.sharedInstance()
    private(set) var engine: AVAudioEngine?
    private var observers: [NSObjectProtocol] = []

    /// Fired when the capture was lost and could not be rebuilt — a phone
    /// call taking the microphone, or a route change the engine did not
    /// survive. The conversation cannot continue deaf, so the owner should
    /// end it and say so rather than listen to silence.
    var onCaptureLost: (() -> Void)?

    var isRunning: Bool { engine?.isRunning == true }

    /// Must be called while the app is in the foreground: this is the one
    /// moment iOS allows a capture to begin.
    func start() throws {
        guard !isRunning else { return }
        // .playAndRecord for the whole conversation: the reply is spoken
        // into the same session that is listening, so neither direction has
        // to reconfigure — reconfiguring is what stopped the capture.
        // .duckOthers rather than .mixWithOthers, because a spoken reply
        // talked over by music is not a reply.
        try session.setCategory(
            .playAndRecord,
            mode: .spokenAudio,
            options: [.duckOthers, .allowBluetoothHFP, .defaultToSpeaker]
        )
        try session.setActive(true)
        try startEngine()
        observe()
    }

    func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        guard let engine else { return }
        engine.stop()
        self.engine = nil
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func startEngine() throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw ConversationAudioError.noInput
        }

        // The input has to be part of the rendering graph to keep capturing.
        // Routing it into a silent mixer keeps the graph live without
        // monitoring the microphone back through the speaker.
        engine.connect(input, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 0
        engine.prepare()
        try engine.start()
        self.engine = engine
    }

    /// Rebuilds the capture after the system pulled it out from under us.
    private func restart() throws {
        engine?.stop()
        engine = nil
        try session.setActive(true)
        try startEngine()
    }

    private func observe() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default

        // A phone call, a timer, Siri: the session is taken and handed back.
        // Resuming is only allowed when the system says so, and even then it
        // can fail if the interruption is still on screen.
        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: session,
            queue: .main
        ) { [weak self] notification in
            guard let value = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: value)
            else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                switch type {
                case .began:
                    self.engine?.stop()
                case .ended:
                    let options = (notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt)
                        .map(AVAudioSession.InterruptionOptions.init(rawValue:)) ?? []
                    guard options.contains(.shouldResume) else {
                        self.reportCaptureLost("interruption ended without resume")
                        return
                    }
                    self.recover(after: "interruption")
                @unknown default:
                    break
                }
            }
        })

        // Headphones in or out rebuilds the graph; the old engine is dead.
        observers.append(center.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self, notification.object as? AVAudioEngine === self.engine else { return }
                self.recover(after: "configuration change")
            }
        })
    }

    private func recover(after reason: String) {
        do {
            try restart()
            AgentTurnLog.note("conversation audio recovered after \(reason)")
        } catch {
            reportCaptureLost("\(reason): \(error.localizedDescription)")
        }
    }

    private func reportCaptureLost(_ reason: String) {
        AgentTurnLog.note("conversation audio lost — \(reason)")
        onCaptureLost?()
    }

    enum ConversationAudioError: LocalizedError {
        case noInput
        var errorDescription: String? { "No microphone input is available." }
    }
}
