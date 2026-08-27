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
        case connecting
        /// The live transport dropped and is being re-established. The
        /// conversation is still open, so this is not a failure yet.
        case reconnecting
        case recording
        case transcribing
        case speaking
        case failed(String)
    }

    private(set) var phase: Phase = .ready
    private(set) var messages = [
        VoiceAgentMessage(
            role: .hermes,
            text: "Talk to me naturally. I can have a real conversation, prepare messages, email, and notes, or open supported apps after you approve."
        ),
    ]
    private(set) var audioLevel: Float = 0
    private(set) var elapsedSeconds = 0
    private(set) var session = VoiceAgentSession()
    private(set) var conversationActive = false
    private(set) var usesRealtime = false
    private(set) var conversationHistory: [HermesConversation] = []
    private(set) var usageSummary = HermesUsageSummary(
        conversationCount: 0,
        spokenWordCount: 0,
        totalCapturedWordCount: 0
    )
    var showsMicrophoneSettings = false
    var sharePayload: VoiceAgentSharePayload?
    var messagePayload: MessageComposePayload?
    /// Where in-app notes and reminders go; injected by the root view.
    @ObservationIgnored var notes: NotesController?
    /// Releases any audio the rest of the app is holding.
    ///
    /// The resident listening window keeps a capture engine running for
    /// background dictation. Starting a conversation on top of it makes the
    /// keepalive and the agent reconfigure the audio session against each
    /// other — the keepalive rebuilds its graph, takes the session back, and
    /// the conversation dies before the user can say anything. The root view
    /// wires this to close the window first, synchronously, so the handoff
    /// happens in a defined order instead of whenever SwiftUI notices.
    @ObservationIgnored var prepareForExclusiveAudio: (@MainActor () -> Void)?
    /// Mirrors the user's speaker preference into the live audio route.
    var usesSpeaker = true {
        didSet { realtimeClient.setSpeakerEnabled(usesSpeaker) }
    }
    /// Mirrors Settings; applied to every email the agent prepares.
    var emailDelivery: EmailDelivery = .mailApp {
        didSet { session.emailDelivery = emailDelivery }
    }
    @ObservationIgnored private let backend = HermesBackendClient()

    private let recorder: DictationAudioRecorder
    private let transcriber: DictationTranscriber
    private let speaker = VoiceAgentSpeaker()
    private let realtimeClient = RealtimeAgentClient()
    private let conversationStore: HermesConversationStore
    private let transcriptStore: TranscriptStore
    private var pendingRealtimeAction: VoiceAgentAction?
    private var turnDetector = VoiceTurnDetector()
    private var conversationID: UUID?
    private var conversationSettings: SharedState?
    private var isCompletingTurn = false
    @ObservationIgnored
    nonisolated(unsafe) private var elapsedTask: Task<Void, Never>?

    init(
        recorder: DictationAudioRecorder = DictationAudioRecorder(),
        transcriber: DictationTranscriber = DictationTranscriber(),
        conversationStore: HermesConversationStore = HermesConversationStore(),
        transcriptStore: TranscriptStore = TranscriptStore()
    ) {
        self.recorder = recorder
        self.transcriber = transcriber
        self.conversationStore = conversationStore
        self.transcriptStore = transcriptStore
        recorder.onLevel = { [weak self] level in
            Task { @MainActor in self?.handleAudioLevel(level) }
        }
        recorder.onInterruption = { [weak self] in
            Task { @MainActor in await self?.endConversation(announce: false) }
        }
        realtimeClient.onStateChange = { [weak self] state in
            self?.handleRealtimeState(state)
        }
        realtimeClient.onUserTranscript = { [weak self] transcript in
            self?.handleRealtimeUserTranscript(transcript)
        }
        realtimeClient.onAssistantTranscript = { [weak self] transcript in
            self?.appendRealtimeMessage(role: .hermes, text: transcript)
        }
        realtimeClient.onInformationRequest = { [weak self] name, arguments in
            await self?.runInformationTool(name, arguments) ?? "No result was available."
        }
        realtimeClient.onPreparedAction = { [weak self] prepared in
            guard let self else { return }
            self.handleRealtimeAction(RealtimePreparedAction(
                callID: prepared.callID,
                action: prepared.action.retargetedEmail(to: self.emailDelivery)
            ))
        }
        refreshHistory()
    }

    deinit {
        elapsedTask?.cancel()
    }

    var isRecording: Bool { phase == .recording }
    var isBusy: Bool { phase == .connecting || phase == .transcribing || phase == .speaking }
    var isReconnecting: Bool { phase == .reconnecting }
    var pendingAction: VoiceAgentAction? { pendingRealtimeAction ?? session.pendingAction }
    var canUseOfflineMode: Bool {
        if case .failed = phase { return !conversationActive }
        return false
    }
    var primaryAction: VoiceAgentPrimaryAction {
        if usesRealtime && conversationActive { return .finishTurn }
        return VoiceAgentControlPolicy.primaryAction(
            conversationActive: conversationActive,
            recording: isRecording,
            busy: isBusy
        )
    }

    var statusText: String {
        switch phase {
        case .ready: conversationActive ? "Ready for your next request" : "Ready for a conversation"
        case .connecting: "Connecting to Hermes Realtime…"
        case .reconnecting: "Connection dropped — reconnecting…"
        case .recording: "Listening — speak naturally…"
        case .transcribing: "Understanding on this iPhone…"
        case .speaking: usesRealtime ? "Hermes is responding…" : "Speaking…"
        case .failed(let message): message
        }
    }

    func performPrimaryAction(settings: SharedState) async {
        if usesRealtime, conversationActive {
            await endConversation()
            return
        }
        switch primaryAction {
        case .startConversation:
            await startConversation(settings: settings)
        case .finishTurn:
            await finishCurrentTurn(settings: settings)
        case .wait:
            return
        }
    }

    func finishCurrentTurn(settings: SharedState) async {
        guard conversationActive,
              isRecording,
              !isCompletingTurn,
              let conversationID
        else { return }

        isCompletingTurn = true
        await stopAndProcess(settings: settings, conversationID: conversationID)
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
        if let action = pendingRealtimeAction {
            if let conversationID { try? conversationStore.end(id: conversationID) }
            pendingRealtimeAction = nil
            usesRealtime = false
            conversationActive = false
            realtimeClient.stop()
            conversationID = nil
            conversationSettings = nil
            refreshHistory()
            messages.append(VoiceAgentMessage(role: .person, text: "Confirm"))
            await execute(action)
            return
        }
        discardCurrentRecording()
        messages.append(VoiceAgentMessage(role: .person, text: "Confirm"))
        await handle(session.confirm())
    }

    func cancelPending() async {
        guard pendingAction != nil || session.step != .idle else { return }
        if pendingRealtimeAction != nil {
            pendingRealtimeAction = nil
            messages.append(VoiceAgentMessage(role: .person, text: "Cancel"))
            messages.append(VoiceAgentMessage(role: .hermes, text: "Cancelled. Nothing was opened or shared."))
            return
        }
        discardCurrentRecording()
        messages.append(VoiceAgentMessage(role: .person, text: "Cancel"))
        await handle(session.cancel(), resumeConversation: conversationActive)
    }

    func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private func startConversation(settings: SharedState) async {
        guard await microphonePermission() else {
            phase = .failed("Microphone access is off. Enable it in Settings to talk to Hermes.")
            showsMicrophoneSettings = true
            return
        }

        prepareForExclusiveAudio?()

        let id = UUID()
        conversationActive = true
        conversationID = id
        conversationSettings = settings
        phase = .connecting
        usesRealtime = true
        do {
            try await realtimeClient.start()
            try? conversationStore.begin(id: id, mode: .realtime)
            refreshHistory()
            messages.append(
                VoiceAgentMessage(
                    role: .hermes,
                    text: "Live conversation started. Speak naturally, interrupt me when you need to, or ask me to open a supported app."
                )
            )
            return
        } catch {
            realtimeClient.stop()
            usesRealtime = false
            conversationActive = false
            conversationID = nil
            conversationSettings = nil
            let message = "\(error.localizedDescription) Offline voice was not started automatically."
            phase = .failed(message)
            messages.append(
                VoiceAgentMessage(
                    role: .hermes,
                    text: message
                )
            )
            return
        }
    }

    func startOfflineConversation(settings: SharedState) async {
        guard !conversationActive else { return }
        let id = UUID()
        conversationActive = true
        conversationID = id
        conversationSettings = settings
        usesRealtime = false
        guard await startRecording(settings: settings) else {
            conversationActive = false
            conversationID = nil
            conversationSettings = nil
            return
        }
        try? conversationStore.begin(id: id, mode: .offline)
        refreshHistory()
        messages.append(
            VoiceAgentMessage(
                role: .hermes,
                text: "Offline conversation started. This mode transcribes first and uses the iPhone system voice."
            )
        )
    }

    private func startRecording(settings: SharedState) async -> Bool {
        guard !isBusy else { return false }
        speaker.stop()
        prepareForExclusiveAudio?()

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
        guard let samples = recorder.stop() else {
            if isRecording { phase = .failed("The recording was empty. Please try again.") }
            return
        }
        elapsedTask?.cancel()
        elapsedTask = nil
        phase = .transcribing

        let modelPath = settings.modelFolderPath
        guard let modelPath else {
            phase = .failed("The speech model is missing. Prepare it again in Dictation.")
            conversationActive = false
            return
        }

        do {
            let rawText = try await transcriber.transcribe(samples: samples, modelPath: modelPath)
            guard conversationActive, conversationID == expectedConversationID else { return }
            let collectsProse = session.step.collectsProse
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
        persistTurn(cleaned, role: .person)
        await handle(session.receive(cleaned), resumeConversation: resumeConversation)
    }

    private func handle(_ turn: VoiceAgentTurn, resumeConversation: Bool = false) async {
        messages.append(VoiceAgentMessage(role: .hermes, text: turn.assistantMessage))
        persistTurn(turn.assistantMessage, role: .hermes)
        phase = .speaking
        await speaker.speak(turn.assistantMessage)
        phase = .ready
        if let action = turn.action {
            if let conversationID { try? conversationStore.end(id: conversationID) }
            conversationActive = false
            conversationID = nil
            conversationSettings = nil
            refreshHistory()
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
        let endingConversationID = conversationID
        discardCurrentRecording()
        conversationActive = false
        conversationID = nil
        conversationSettings = nil
        let message = "I paused because I didn't hear anything. Tap Start conversation when you're ready."
        messages.append(VoiceAgentMessage(role: .hermes, text: message))
        phase = .speaking
        await speaker.speak(message)
        phase = .ready
        if let endingConversationID {
            try? conversationStore.end(id: endingConversationID)
            refreshHistory()
        }
    }

    func endConversation(announce: Bool = true) async {
        let wasActive = conversationActive || isRecording || isBusy
        let endingConversationID = conversationID
        conversationActive = false
        conversationID = nil
        conversationSettings = nil
        pendingRealtimeAction = nil
        realtimeClient.stop()
        usesRealtime = false
        speaker.stop()
        discardCurrentRecording()
        phase = .ready
        if let endingConversationID {
            try? conversationStore.end(id: endingConversationID)
            refreshHistory()
        }
        guard announce, wasActive else { return }
        messages.append(VoiceAgentMessage(role: .hermes, text: "Conversation ended."))
    }

    private func discardCurrentRecording() {
        _ = recorder.stop()
        elapsedTask?.cancel()
        elapsedTask = nil
        audioLevel = 0
        isCompletingTurn = false
    }

    // MARK: - Read-only tools

    /// Runs a tool that only reads and returns what Hermes should hear back.
    ///
    /// These bypass the confirmation flow on purpose: there is nothing to undo
    /// in a search or a lookup, and making the user approve one would turn
    /// "what's the weather" into a dialog box.
    private func runInformationTool(_ name: String, _ arguments: [String: Any]) async -> String {
        switch name {
        case "get_datetime":
            let formatter = DateFormatter()
            formatter.dateFormat = "EEEE, d MMMM yyyy 'at' h:mm a zzz"
            return "It is currently \(formatter.string(from: Date())) in \(TimeZone.current.identifier)."

        case "search_web":
            guard let query = (arguments["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !query.isEmpty
            else { return "No search query was provided." }
            do {
                let result = try await HermesBackendClient().search(query)
                guard !result.answer.isEmpty else { return "The search returned nothing useful." }
                let sources = result.sources.prefix(3).map(\.title).joined(separator: ", ")
                return sources.isEmpty ? result.answer : "\(result.answer) (Sources: \(sources).)"
            } catch {
                return "The web search failed: \(error.localizedDescription)"
            }

        case "search_notes":
            guard let notes else { return "Notes are not available right now." }
            let query = (arguments["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let matches = query.isEmpty ? Array(notes.notes.prefix(5)) : Array(notes.search(query).prefix(5))
            guard !matches.isEmpty else {
                return query.isEmpty ? "There are no saved notes." : "No notes match \"\(query)\"."
            }
            return matches
                .map { "\($0.title): \($0.body.prefix(200))" }
                .joined(separator: " | ")

        case "list_reminders":
            guard let notes else { return "Reminders are not available right now." }
            await notes.refreshReminders()
            let upcoming = notes.reminders.filter { !$0.isCompleted }.prefix(8)
            guard !upcoming.isEmpty else { return "There are no upcoming reminders." }
            let formatter = DateFormatter()
            formatter.dateFormat = "EEEE d MMMM 'at' h:mm a"
            return upcoming
                .map { item in
                    guard let due = item.dueDate else { return item.title }
                    return "\(item.title), due \(formatter.string(from: due))"
                }
                .joined(separator: " | ")

        default:
            return "That tool is not available."
        }
    }

    private func execute(_ action: VoiceAgentAction) async {
        switch action {
        case .composeEmail(let draft):
            guard let url = VoiceAgentHandoff.mailtoURL(for: draft) else {
                await reportHandoffFailure("I couldn't create a safe email draft. Please review the address and try again.")
                return
            }
            await open(url, failureMessage: "I couldn't open your default mail app. Check that a mail app is configured.")
        case .sendEmail(let draft):
            do {
                _ = try await backend.sendEmail(draft, mode: .send)
                await announce("Sent to \(draft.recipient).")
            } catch {
                await reportHandoffFailure(error.localizedDescription)
            }
        case .shareNote(let text):
            sharePayload = VoiceAgentSharePayload(text: text)
        case .saveNote(let text):
            guard let notes, notes.saveNote(text) != nil else {
                await reportHandoffFailure(notes?.lastError ?? "I couldn't save the note.")
                return
            }
            await announce("Saved to your notes.")
        case .createReminder(let draft):
            guard let notes, await notes.addReminder(draft) != nil else {
                await reportHandoffFailure(notes?.lastError ?? "I couldn't add the reminder.")
                return
            }
            await announce(draft.dueDate == nil ? "Reminder added." : "Reminder added with an alert.")
        case .composeMessage(let text):
            messagePayload = MessageComposePayload(
                body: text,
                recipients: conversationSettings?.messageRecipients ?? []
            )
        case .open(.gmailWeb):
            guard let url = URL(string: "https://mail.google.com/") else { return }
            await open(url, failureMessage: "I couldn't open Gmail in your browser.")
        case .open(.appSettings):
            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
            await open(url, failureMessage: "I couldn't open Settings.")
        case .open(.maps):
            await openDestination("https://maps.apple.com/", name: "Maps")
        case .open(.calendar):
            await openDestination("calshow://", name: "Calendar")
        case .open(.music):
            await openDestination("music://", name: "Music")
        case .open(.youtube):
            await openDestination("https://www.youtube.com/", name: "YouTube")
        case .open(.spotify):
            await openDestination("https://open.spotify.com/", name: "Spotify")
        case .runShortcut(let name):
            var components = URLComponents()
            components.scheme = "shortcuts"
            components.host = "run-shortcut"
            components.queryItems = [URLQueryItem(name: "name", value: name)]
            guard let url = components.url else {
                await reportHandoffFailure("I couldn't create a safe Shortcuts handoff.")
                return
            }
            await open(url, failureMessage: "I couldn't find or run the \(name) shortcut.")
        }
    }

    private func openDestination(_ value: String, name: String) async {
        guard let url = URL(string: value) else { return }
        await open(url, failureMessage: "I couldn't open \(name) on this iPhone.")
    }

    private func handleRealtimeState(_ state: RealtimeAgentClient.State) {
        guard usesRealtime || state == .connecting else { return }
        switch state {
        case .disconnected:
            if conversationActive { phase = .failed("The live conversation disconnected. Tap to start again.") }
        case .connecting:
            phase = .connecting
        case .interrupted:
            // Not an ending: the transport is being re-checked and usually
            // comes straight back. Say so rather than tearing the call down.
            if conversationActive { phase = .reconnecting }
        case .listening:
            phase = .recording
        case .responding:
            phase = .speaking
        case .failed(let message):
            if let conversationID { try? conversationStore.end(id: conversationID) }
            realtimeClient.stop()
            phase = .failed(message)
            conversationActive = false
            usesRealtime = false
            pendingRealtimeAction = nil
            conversationID = nil
            conversationSettings = nil
            // Without this the reason only ever appears in the status line,
            // which the next state change overwrites.
            messages.append(VoiceAgentMessage(role: .hermes, text: message))
            refreshHistory()
        }
    }

    private func handleRealtimeUserTranscript(_ transcript: String) {
        appendRealtimeMessage(role: .person, text: transcript)
        guard pendingRealtimeAction != nil,
              let decision = VoiceAgentApprovalDecision(spoken: transcript)
        else { return }
        Task {
            switch decision {
            case .confirm:
                guard let action = pendingRealtimeAction else { return }
                pendingRealtimeAction = nil
                realtimeClient.stop()
                usesRealtime = false
                conversationActive = false
                await execute(action)
            case .cancel:
                pendingRealtimeAction = nil
                messages.append(VoiceAgentMessage(role: .hermes, text: "Cancelled. Nothing was opened or shared."))
            }
        }
    }

    private func appendRealtimeMessage(role: VoiceAgentMessage.Role, text: String) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        messages.append(VoiceAgentMessage(role: role, text: value))
        persistTurn(value, role: role == .person ? .person : .hermes)
    }

    func clearConversationHistory() {
        conversationStore.clear()
        refreshHistory()
    }

    private func persistTurn(_ text: String, role: HermesConversationRole) {
        guard let conversationID else { return }
        try? conversationStore.append(text, role: role, to: conversationID)
        refreshHistory()
    }

    private func refreshHistory() {
        conversationHistory = conversationStore.history
        let dictatedWords = transcriptStore.history.reduce(0) {
            $0 + $1.text.split(whereSeparator: \Character.isWhitespace).count
        }
        usageSummary = conversationStore.summary(dictatedWordCount: dictatedWords)
    }

    private func handleRealtimeAction(_ prepared: RealtimePreparedAction) {
        guard pendingRealtimeAction == nil else {
            realtimeClient.completeFunctionCall(
                id: prepared.callID,
                output: "Rejected: another action is already waiting for confirmation."
            )
            return
        }
        pendingRealtimeAction = prepared.action
        realtimeClient.completeFunctionCall(
            id: prepared.callID,
            output: "Prepared for review. Ask the user to say confirm or cancel. Do not claim it has happened."
        )
    }

    private func open(_ url: URL, failureMessage: String) async {
        let opened = await UIApplication.shared.open(url)
        if !opened {
            await reportHandoffFailure(failureMessage)
        }
    }

    private func announce(_ message: String) async {
        messages.append(VoiceAgentMessage(role: .hermes, text: message))
        phase = .speaking
        await speaker.speak(message)
        phase = .ready
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
    private let audioSession = AVAudioSession.sharedInstance()
    private var continuation: CheckedContinuation<Void, Never>?
    private var utterance: AVSpeechUtterance?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String) async {
        stop()
        do {
            try audioSession.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try audioSession.setActive(true)
        } catch {
            NSLog("WhisperDict speech audio setup failed: \(error.localizedDescription)")
        }
        let utterance = AVSpeechUtterance(string: text)
        let language = Locale.current.identifier.replacingOccurrences(of: "_", with: "-")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.92
        utterance.pitchMultiplier = 0.98
        utterance.voice = Self.preferredVoice(for: language)
        self.utterance = utterance

        await withCheckedContinuation { continuation in
            self.continuation = continuation
            synthesizer.speak(utterance)
        }
    }

    private static func preferredVoice(for language: String) -> AVSpeechSynthesisVoice? {
        let requestedLanguage = Locale(identifier: language).language.languageCode?.identifier
        let matchingVoices = AVSpeechSynthesisVoice.speechVoices().filter { voice in
            voice.language == language
                || Locale(identifier: voice.language).language.languageCode?.identifier == requestedLanguage
        }

        return matchingVoices.max { lhs, rhs in
            voiceScore(lhs, requestedLanguage: language) < voiceScore(rhs, requestedLanguage: language)
        } ?? AVSpeechSynthesisVoice(language: language)
    }

    private static func voiceScore(_ voice: AVSpeechSynthesisVoice, requestedLanguage: String) -> Int {
        let localeBonus = voice.language == requestedLanguage ? 10 : 0
        return voice.quality.rawValue * 100 + localeBonus
    }

    func stop() {
        continuation?.resume()
        continuation = nil
        utterance = nil
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
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
        try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
    }
}
