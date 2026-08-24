import AVFoundation
import Foundation
import Observation
import UIKit

struct VoiceAgentMessage: Identifiable, Equatable {
    enum Role {
        case person
        case hermes
    }

    let id = UUID()
    let role: Role
    let text: String
}

struct VoiceAgentSharePayload: Identifiable {
    let id = UUID()
    let text: String
}

@MainActor
@Observable
final class VoiceAgentController {
    enum Phase: Equatable {
        case ready
        case recording
        case transcribing
        case speaking
        case failed(String)
    }

    private(set) var phase: Phase = .ready
    private(set) var messages = [
        VoiceAgentMessage(
            role: .hermes,
            text: "Tell me to compose an email, create a note, open Gmail, or open Settings."
        ),
    ]
    private(set) var audioLevel: Float = 0
    private(set) var elapsedSeconds = 0
    private(set) var session = VoiceAgentSession()
    private(set) var conversationActive = false
    var showsMicrophoneSettings = false
    var sharePayload: VoiceAgentSharePayload?

    private let recorder: DictationAudioRecorder
    private let transcriber: DictationTranscriber
    private let speaker = VoiceAgentSpeaker()
    private var turnDetector = VoiceTurnDetector()
    private var conversationID: UUID?
    private var conversationSettings: SharedState?
    private var isCompletingTurn = false
    @ObservationIgnored
    nonisolated(unsafe) private var elapsedTask: Task<Void, Never>?

    init(
        recorder: DictationAudioRecorder = DictationAudioRecorder(),
        transcriber: DictationTranscriber = DictationTranscriber()
    ) {
        self.recorder = recorder
        self.transcriber = transcriber
        recorder.onLevel = { [weak self] level in
            Task { @MainActor in self?.handleAudioLevel(level) }
        }
        recorder.onInterruption = { [weak self] in
            Task { @MainActor in await self?.endConversation(announce: false) }
        }
    }

    deinit {
        elapsedTask?.cancel()
    }

    var isRecording: Bool { phase == .recording }
    var isBusy: Bool { phase == .transcribing || phase == .speaking }
    var pendingAction: VoiceAgentAction? { session.pendingAction }

    var statusText: String {
        switch phase {
        case .ready: conversationActive ? "Ready for your next request" : "Ready for a conversation"
        case .recording: "Listening — speak naturally…"
        case .transcribing: "Understanding on this iPhone…"
        case .speaking: "Speaking…"
        case .failed(let message): message
        }
    }

    func toggleConversation(settings: SharedState) async {
        if conversationActive {
            await endConversation()
        } else {
            await startConversation(settings: settings)
        }
    }

    func stopIfNeeded(settings: SharedState) async {
        guard conversationActive || isRecording || isBusy else { return }
        await endConversation(announce: false)
    }

    func submitText(_ text: String) async {
        guard !isRecording, !isBusy else { return }
        await process(text)
    }

    func confirmPending() async {
        guard pendingAction != nil else { return }
        discardCurrentRecording()
        messages.append(VoiceAgentMessage(role: .person, text: "Confirm"))
        await handle(session.confirm())
    }

    func cancelPending() async {
        guard pendingAction != nil || session.step != .idle else { return }
        discardCurrentRecording()
        messages.append(VoiceAgentMessage(role: .person, text: "Cancel"))
        await handle(session.cancel(), resumeConversation: conversationActive)
    }

    func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private func startConversation(settings: SharedState) async {
        conversationActive = true
        conversationID = UUID()
        conversationSettings = settings
        guard await startRecording(settings: settings) else {
            conversationActive = false
            conversationID = nil
            conversationSettings = nil
            return
        }
        messages.append(
            VoiceAgentMessage(
                role: .hermes,
                text: "Conversation started. Speak naturally; I'll answer and listen again automatically."
            )
        )
    }

    private func startRecording(settings: SharedState) async -> Bool {
        guard !isBusy else { return false }
        speaker.stop()

        let defaults = UserDefaults(suiteName: SharedState.appGroupID)
        guard let modelPath = settings.modelFolderPath,
              FileManager.default.fileExists(atPath: modelPath)
        else {
            phase = .failed("Prepare the speech model in Dictation before using the agent.")
            return false
        }
        let preparedModel = defaults?.string(forKey: "preparedModelSize")
        guard preparedModel == settings.modelSize.rawValue || modelPath.localizedCaseInsensitiveContains(settings.modelSize.rawValue) else {
            phase = .failed("Prepare the selected \(settings.modelSize.title) model before using the agent.")
            return false
        }

        guard await microphonePermission() else {
            phase = .failed("Microphone access is off. Enable it in Settings to talk to Hermes.")
            showsMicrophoneSettings = true
            return false
        }

        do {
            try recorder.start()
            elapsedSeconds = 0
            audioLevel = 0
            phase = .recording
            isCompletingTurn = false
            turnDetector.reset(at: ProcessInfo.processInfo.systemUptime)
            startElapsedTimer()
            return true
        } catch {
            phase = .failed(error.localizedDescription)
            return false
        }
    }

    private func stopAndProcess(settings: SharedState, conversationID expectedConversationID: UUID) async {
        guard let audioURL = recorder.stop() else {
            if isRecording { phase = .failed("The recording was empty. Please try again.") }
            return
        }
        elapsedTask?.cancel()
        elapsedTask = nil
        phase = .transcribing

        defer { try? FileManager.default.removeItem(at: audioURL) }
        let modelPath = settings.modelFolderPath
        guard let modelPath else {
            phase = .failed("The speech model is missing. Prepare it again in Dictation.")
            conversationActive = false
            return
        }

        do {
            let rawText = try await transcriber.transcribe(audioURL: audioURL, modelPath: modelPath)
            guard conversationActive, conversationID == expectedConversationID else { return }
            let collectsProse = session.step == .collectingEmailBody || session.step == .collectingNote
            let options = TranscriptCleanupOptions(
                removeFillers: settings.removeFillers,
                autoPunctuate: collectsProse && settings.autoPunctuate,
                autoCapitalize: collectsProse && settings.autoCapitalize
            )
            let transcript = TranscriptCleaner.clean(rawText, options: options)
            phase = .ready
            await process(transcript, resumeConversation: true)
        } catch {
            guard conversationActive, conversationID == expectedConversationID else { return }
            messages.append(VoiceAgentMessage(role: .hermes, text: "I didn't catch that. I'm listening again."))
            phase = .speaking
            await speaker.speak("I didn't catch that. I'm listening again.")
            phase = .ready
            _ = await startRecording(settings: settings)
        }
    }

    private func process(_ text: String, resumeConversation: Bool = false) async {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            if resumeConversation, conversationActive, let conversationSettings {
                _ = await startRecording(settings: conversationSettings)
            }
            return
        }
        messages.append(VoiceAgentMessage(role: .person, text: cleaned))
        await handle(session.receive(cleaned), resumeConversation: resumeConversation)
    }

    private func handle(_ turn: VoiceAgentTurn, resumeConversation: Bool = false) async {
        messages.append(VoiceAgentMessage(role: .hermes, text: turn.assistantMessage))
        phase = .speaking
        await speaker.speak(turn.assistantMessage)
        phase = .ready
        if let action = turn.action {
            conversationActive = false
            conversationID = nil
            conversationSettings = nil
            await execute(action)
            return
        }
        if resumeConversation, conversationActive, let conversationSettings {
            _ = await startRecording(settings: conversationSettings)
        }
    }

    private func handleAudioLevel(_ level: Float) {
        audioLevel = level
        guard conversationActive, isRecording, !isCompletingTurn else { return }
        let result = turnDetector.observe(level: level, at: ProcessInfo.processInfo.systemUptime)
        switch result {
        case .listening:
            return
        case .finishTurn:
            guard let conversationSettings, let conversationID else { return }
            isCompletingTurn = true
            Task { await stopAndProcess(settings: conversationSettings, conversationID: conversationID) }
        case .idleTimeout:
            isCompletingTurn = true
            Task { await endForIdleTimeout() }
        }
    }

    private func endForIdleTimeout() async {
        discardCurrentRecording()
        conversationActive = false
        conversationID = nil
        conversationSettings = nil
        let message = "I paused because I didn't hear anything. Tap Start conversation when you're ready."
        messages.append(VoiceAgentMessage(role: .hermes, text: message))
        phase = .speaking
        await speaker.speak(message)
        phase = .ready
    }

    private func endConversation(announce: Bool = true) async {
        let wasActive = conversationActive || isRecording || isBusy
        conversationActive = false
        conversationID = nil
        conversationSettings = nil
        speaker.stop()
        discardCurrentRecording()
        phase = .ready
        guard announce, wasActive else { return }
        messages.append(VoiceAgentMessage(role: .hermes, text: "Conversation ended."))
    }

    private func discardCurrentRecording() {
        if let audioURL = recorder.stop() {
            try? FileManager.default.removeItem(at: audioURL)
        }
        elapsedTask?.cancel()
        elapsedTask = nil
        audioLevel = 0
        isCompletingTurn = false
    }

    private func execute(_ action: VoiceAgentAction) async {
        switch action {
        case .composeEmail(let draft):
            guard let url = VoiceAgentHandoff.mailtoURL(for: draft) else {
                await reportHandoffFailure("I couldn't create a safe email draft. Please review the address and try again.")
                return
            }
            await open(url, failureMessage: "I couldn't open your default mail app. Check that a mail app is configured.")
        case .shareNote(let text):
            sharePayload = VoiceAgentSharePayload(text: text)
        case .open(.gmailWeb):
            guard let url = URL(string: "https://mail.google.com/") else { return }
            await open(url, failureMessage: "I couldn't open Gmail in your browser.")
        case .open(.appSettings):
            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
            await open(url, failureMessage: "I couldn't open Settings.")
        }
    }

    private func open(_ url: URL, failureMessage: String) async {
        let opened = await UIApplication.shared.open(url)
        if !opened {
            await reportHandoffFailure(failureMessage)
        }
    }

    private func reportHandoffFailure(_ message: String) async {
        messages.append(VoiceAgentMessage(role: .hermes, text: message))
        phase = .failed(message)
        await speaker.speak(message)
    }

    private func microphonePermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return true
        case .denied: return false
        case .undetermined:
            return await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        @unknown default: return false
        }
    }

    private func startElapsedTimer() {
        elapsedTask?.cancel()
        elapsedTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self, self.isRecording else { return }
                self.elapsedSeconds += 1
            }
        }
    }
}

@MainActor
private final class VoiceAgentSpeaker: NSObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private var continuation: CheckedContinuation<Void, Never>?
    private var utterance: AVSpeechUtterance?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String) async {
        stop()
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.voice = AVSpeechSynthesisVoice(language: Locale.current.language.languageCode?.identifier ?? "en-US")
        self.utterance = utterance

        await withCheckedContinuation { continuation in
            self.continuation = continuation
            synthesizer.speak(utterance)
        }
    }

    func stop() {
        continuation?.resume()
        continuation = nil
        utterance = nil
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in self?.finish(utterance) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in self?.finish(utterance) }
    }

    private func finish(_ completedUtterance: AVSpeechUtterance) {
        guard utterance === completedUtterance else { return }
        utterance = nil
        continuation?.resume()
        continuation = nil
    }
}
