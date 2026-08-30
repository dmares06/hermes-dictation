import AVFoundation
import Foundation
import Observation
import UIKit

struct VoiceAgentMessage: Identifiable, Equatable {
    enum Role {
        case person
        case hermes
        /// A timeline marker rather than something anyone said — rendered as a
        /// centred date separator the way Messages breaks up a thread.
        case milestone
    }

    let id = UUID()
    let role: Role
    var text: String
    let createdAt: Date = Date()
    /// Thumbnails of photos the person attached, shown inside their bubble.
    var images: [UIImage] = []
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
        case recording
        case transcribing
        /// Hermes Agent is reasoning or running a tool on the Mac.
        case thinking
        case speaking
        case failed(String)
    }

    private(set) var phase: Phase = .ready {
        didSet {
            // The voice speaks no filler while Hermes works, so on a live
            // call the thinking phase ticks softly instead of going dead.
            earcon.setActive(phase == .thinking && usesRealtime && conversationActive)
        }
    }
    /// Starts empty: the thread is the person's, not a place for a canned
    /// greeting they have to scroll past.
    private(set) var messages: [VoiceAgentMessage] = []
    private(set) var audioLevel: Float = 0
    private(set) var elapsedSeconds = 0
    private(set) var session = VoiceAgentSession()
    private(set) var conversationActive = false
    private(set) var usesRealtime = false
    private(set) var conversationHistory: [HermesConversation] = []
    private(set) var memories: [HermesMemory] = []
    /// What Hermes is doing mid-turn, e.g. "Searching the web…".
    private(set) var activity: String?
    private(set) var usesHermes = false
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
    /// Called just before the agent takes the audio session, so whatever
    /// else holds it — the background listening window — can let go first.
    /// This has to be a direct call, not an observer: an `onChange` fires
    /// after the recorder has started, and deactivating the session under a
    /// running engine leaves the microphone silently delivering nothing.
    @ObservationIgnored var onWillTakeAudioSession: (() -> Void)?
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
    private let earcon = ThinkingEarcon()
    private let realtimeClient = RealtimeAgentClient()
    private let hermesClient = HermesAgentClient()
    private let conversationStore: HermesConversationStore
    private let transcriptStore: TranscriptStore
    private let memoryStore: HermesMemoryStore
    private var pendingRealtimeAction: VoiceAgentAction?
    /// An action Hermes Agent proposed, waiting on the confirmation card.
    private var pendingLocalAction: VoiceAgentAction?
    private var hermesConfiguration: HermesAgentClient.Configuration?
    private var hermesTurn: Task<Void, Never>?
    /// Requests the voice relayed while an earlier one was still with Hermes.
    /// They are sent together as one turn when it comes back — the user kept
    /// talking, so they are one thought — and only the newest is spoken.
    private var relayQueue: [RelayWaiter] = []
    private var relayWorker: Task<Void, Never>?
    /// The phone's city, folded into every Hermes prompt.
    let place = PlaceContext()
    /// Typed messages outside a call share one Hermes session per launch,
    /// so a follow-up typed a minute later still has its context.
    private var textConfiguration: HermesAgentClient.Configuration?
    private var textConversationID: UUID?
    private(set) var isTypingTurn = false

    private struct RelayWaiter {
        let request: String
        let continuation: CheckedContinuation<RealtimeFunctionResult, Never>
    }
    /// While an action confirmed by voice is carried out, what would have
    /// been spoken is collected here and handed back to the voice instead.
    private var announcementSink: [String]?
    private var turnDetector = VoiceTurnDetector()
    /// Loudest level seen this turn; tells a silent mic from a quiet room.
    private var turnPeakLevel: Float = 0
    private var conversationID: UUID?
    private var conversationSettings: SharedState?
    private var isCompletingTurn = false
    @ObservationIgnored
    nonisolated(unsafe) private var elapsedTask: Task<Void, Never>?

    init(
        recorder: DictationAudioRecorder = DictationAudioRecorder(),
        transcriber: DictationTranscriber = DictationTranscriber(),
        conversationStore: HermesConversationStore = HermesConversationStore(),
        transcriptStore: TranscriptStore = TranscriptStore(),
        memoryStore: HermesMemoryStore = HermesMemoryStore()
    ) {
        self.recorder = recorder
        self.transcriber = transcriber
        self.conversationStore = conversationStore
        self.transcriptStore = transcriptStore
        self.memoryStore = memoryStore
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
        realtimeClient.onFunctionCall = { [weak self] name, arguments in
            await self?.answerFunctionCall(name, arguments)
                ?? RealtimeFunctionResult(output: "No result was available.", speak: true)
        }
        refreshHistory()
        memories = memoryStore.memories
    }

    deinit {
        elapsedTask?.cancel()
    }

    var isRecording: Bool { phase == .recording }
    var isBusy: Bool {
        phase == .connecting || phase == .transcribing || phase == .thinking || phase == .speaking
    }
    var pendingAction: VoiceAgentAction? { pendingRealtimeAction ?? pendingLocalAction ?? session.pendingAction }
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
        case .connecting: "Connecting to Hermes…"
        case .recording: "Listening — speak naturally…"
        case .transcribing: "Understanding on this iPhone…"
        case .thinking: activity ?? "Hermes is thinking…"
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
            await startLiveCall(settings: settings)
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
        AgentTurnLog.note(String(format: "turn ended by tap; peak level %.2f", turnPeakLevel))
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
            // The call stays up: what happens next is announced through the
            // voice, and leaving the app (to Messages, Maps…) ends it anyway.
            pendingRealtimeAction = nil
            messages.append(VoiceAgentMessage(role: .person, text: "Confirm"))
            await execute(action)
            return
        }
        if let action = pendingLocalAction {
            pendingLocalAction = nil
            discardCurrentRecording()
            messages.append(VoiceAgentMessage(role: .person, text: "Confirm"))
            await execute(action)
            await resumeHermesListening()
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
            if usesRealtime, conversationActive {
                realtimeClient.say("The user cancelled on screen. Nothing was sent, saved, or opened. Acknowledge in a few words.")
            }
            return
        }
        if pendingLocalAction != nil {
            pendingLocalAction = nil
            discardCurrentRecording()
            messages.append(VoiceAgentMessage(role: .person, text: "Cancel"))
            messages.append(VoiceAgentMessage(role: .hermes, text: "Cancelled. Nothing was opened or shared."))
            await resumeHermesListening()
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

    /// The normal way to talk to Hermes: OpenAI Realtime is the ears and the
    /// mouth — instant, interruptible, a natural voice — and every turn is
    /// relayed to Hermes Agent on the Mac, which is the only brain.
    func startLiveCall(settings: SharedState) async {
        guard !conversationActive else { return }
        guard await microphonePermission() else {
            phase = .failed("Microphone access is off. Enable it in Settings to talk to Hermes.")
            showsMicrophoneSettings = true
            return
        }

        let id = UUID()
        do {
            hermesConfiguration = try HermesAgentClient.configuration(
                serverURL: settings.hermesServerURL,
                conversationID: id,
                model: settings.hermesVoiceModel
            )
        } catch {
            phase = .failed(error.localizedDescription)
            messages.append(VoiceAgentMessage(role: .hermes, text: error.localizedDescription))
            return
        }
        place.refresh()
        onWillTakeAudioSession?()
        conversationActive = true
        conversationID = id
        conversationSettings = settings
        phase = .connecting
        usesRealtime = true
        do {
            try await realtimeClient.start()
            try? conversationStore.begin(id: id, mode: .realtime)
            refreshHistory()
            AgentTurnLog.note("live conversation started; hermes at \(settings.hermesServerURL)")
            messages.append(VoiceAgentMessage(role: .milestone, text: "Live conversation"))
            return
        } catch is CancellationError {
            // The handshake was torn down while it was still in flight — an
            // end-conversation tap, or the app leaving the foreground. That
            // teardown already reset the UI, so reporting a failure here would
            // turn the user's own cancel into an error message.
            guard conversationID == id else { return }
            usesRealtime = false
            conversationActive = false
            conversationID = nil
            conversationSettings = nil
            hermesConfiguration = nil
            phase = .ready
            return
        } catch {
            realtimeClient.stop()
            usesRealtime = false
            conversationActive = false
            conversationID = nil
            conversationSettings = nil
            hermesConfiguration = nil
            let message = "\(error.localizedDescription) Tap \"Use slower voice\" to talk to Hermes with this iPhone's own voice."
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

    // MARK: - Hermes Agent

    /// The fallback when the live call cannot be set up: the same Hermes, but
    /// speech is transcribed on the phone and the reply read by the system
    /// voice, with a few seconds' pause per turn.
    func startHermesConversation(settings: SharedState) async {
        guard !conversationActive else { return }
        let id = UUID()
        do {
            hermesConfiguration = try HermesAgentClient.configuration(
                serverURL: settings.hermesServerURL,
                conversationID: id,
                model: settings.hermesVoiceModel
            )
        } catch {
            phase = .failed(error.localizedDescription)
            messages.append(VoiceAgentMessage(role: .hermes, text: error.localizedDescription))
            return
        }
        onWillTakeAudioSession?()
        conversationActive = true
        conversationID = id
        conversationSettings = settings
        usesRealtime = false
        usesHermes = true
        guard await startRecording(settings: settings) else {
            conversationActive = false
            conversationID = nil
            conversationSettings = nil
            usesHermes = false
            hermesConfiguration = nil
            return
        }
        try? conversationStore.begin(id: id, mode: .hermes)
        refreshHistory()
        AgentTurnLog.note("hermes conversation started; server \(settings.hermesServerURL)")
        messages.append(VoiceAgentMessage(role: .milestone, text: "Hermes conversation"))
    }

    /// One turn against the gateway: stream the reply, speak it sentence by
    /// sentence as it arrives, then listen again.
    private func handleHermesTurn(_ text: String) async {
        guard let configuration = hermesConfiguration, let expected = conversationID else { return }

        // "Confirm" and "cancel" answer the card on screen; Hermes never hears them.
        if pendingLocalAction != nil, let decision = VoiceAgentApprovalDecision(spoken: text) {
            switch decision {
            case .confirm: await confirmPending()
            case .cancel: await cancelPending()
            }
            return
        }

        phase = .thinking
        activity = nil
        speaker.stop()
        AgentTurnLog.note("hermes request → \(configuration.baseURL.host ?? "?"): \(text.prefix(80))")
        let requestedAt = Date()
        var spokenSentences = 0

        var speech = HermesStreamedSpeech()
        var bubbleID: UUID?
        var completedText: String?
        var failure: String?
        do {
            for try await event in hermesClient.reply(to: text, configuration: configuration, place: place.spokenDescription) {
                guard conversationID == expected else { return }
                switch event {
                case .created:
                    AgentTurnLog.note(String(format: "hermes stream opened after %.1fs", Date().timeIntervalSince(requestedAt)))
                case .toolStarted(let name, _):
                    AgentTurnLog.note("hermes tool: \(name)")
                    activity = Self.activityLabel(forTool: name)
                case .toolFinished:
                    activity = nil
                case .textDelta(let delta):
                    for sentence in speech.append(delta) {
                        if spokenSentences == 0 {
                            AgentTurnLog.note(String(format: "first sentence after %.1fs", Date().timeIntervalSince(requestedAt)))
                        }
                        spokenSentences += 1
                        speaker.enqueue(sentence)
                    }
                    let shown = speech.displayText
                    if !shown.isEmpty { bubbleID = upsertHermesBubble(id: bubbleID, text: shown) }
                case .completed(_, let full):
                    AgentTurnLog.note(String(format: "hermes completed after %.1fs (%d chars)", Date().timeIntervalSince(requestedAt), full.count))
                    completedText = full
                case .failed(let message):
                    AgentTurnLog.note("hermes failed: \(message)")
                    failure = message
                }
            }
        } catch is CancellationError {
            AgentTurnLog.note("hermes request cancelled")
            return
        } catch {
            AgentTurnLog.note("hermes transport error: \(error.localizedDescription)")
            failure = error.localizedDescription
        }
        activity = nil
        guard conversationID == expected, !Task.isCancelled else { return }

        if let failure {
            failHermesTurn(failure, bubbleID: bubbleID)
            return
        }

        let finished = speech.finish(completedText: completedText)
        let shown = finished.spoken.isEmpty
            ? (finished.action == nil ? "Hermes didn't say anything." : "Prepared something for you to approve.")
            : finished.spoken
        upsertHermesBubble(id: bubbleID, text: shown)
        persistTurn(shown, role: .hermes)
        if let remainder = finished.remainingSpeech { speaker.enqueue(remainder) }
        AgentTurnLog.note("speaking: \(spokenSentences) streamed sentence(s) + \(finished.remainingSpeech?.count ?? 0) chars remainder")

        phase = .speaking
        await speaker.finishSpeaking()
        AgentTurnLog.note("speaking finished")
        guard conversationID == expected else { return }
        phase = .ready

        if let action = finished.action?.retargetedEmail(to: emailDelivery) {
            pendingLocalAction = action
        }
        await resumeHermesListening()
    }

    private func resumeHermesListening() async {
        guard conversationActive, usesHermes, let conversationSettings else { return }
        phase = .ready
        _ = await startRecording(settings: conversationSettings)
    }

    private func failHermesTurn(_ message: String, bubbleID: UUID?) {
        let text = "Hermes couldn't answer: \(message)"
        if let bubbleID, let index = messages.firstIndex(where: { $0.id == bubbleID }) {
            messages.remove(at: index)
        }
        messages.append(VoiceAgentMessage(role: .hermes, text: text))
        if let conversationID { try? conversationStore.end(id: conversationID) }
        conversationActive = false
        conversationID = nil
        conversationSettings = nil
        usesHermes = false
        hermesConfiguration = nil
        refreshHistory()
        phase = .failed(text)
    }

    @discardableResult
    private func upsertHermesBubble(id: UUID?, text: String) -> UUID {
        if let id, let index = messages.firstIndex(where: { $0.id == id }) {
            messages[index].text = text
            return id
        }
        let message = VoiceAgentMessage(role: .hermes, text: text)
        messages.append(message)
        return message.id
    }

    private static func activityLabel(forTool name: String) -> String {
        if name.hasPrefix("web_search") { return "Searching the web…" }
        if name.hasPrefix("web_") { return "Reading a page…" }
        if name.hasPrefix("browser") { return "Using the browser…" }
        if name.contains("memory") { return "Checking memory…" }
        if name == "session_search" { return "Looking through past conversations…" }
        if name.hasPrefix("skill") { return "Using a skill…" }
        if name.contains("delegate") { return "Handing off to a helper…" }
        if name.contains("image") { return "Working on an image…" }
        return "Using \(name.replacingOccurrences(of: "_", with: " "))…"
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
        guard let samples = recorder.stop() else {
            AgentTurnLog.note("recorder returned no samples")
            if isRecording { phase = .failed("The recording was empty. Please try again.") }
            return
        }
        AgentTurnLog.note("transcribing \(samples.count) samples")
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
            AgentTurnLog.note("transcript (\(transcript.count) chars): \(transcript.prefix(80))")
            phase = .ready
            await process(transcript, resumeConversation: true)
        } catch {
            AgentTurnLog.note("transcription failed: \(error.localizedDescription)")
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
            AgentTurnLog.note("empty transcript; listening again")
            if resumeConversation, conversationActive, let conversationSettings {
                _ = await startRecording(settings: conversationSettings)
            }
            return
        }
        messages.append(VoiceAgentMessage(role: .person, text: cleaned))
        persistTurn(cleaned, role: .person)
        if usesHermes {
            // Held in a task so ending the conversation can cut the stream
            // off mid-reply instead of waiting for Hermes to finish.
            let turn = Task { await self.handleHermesTurn(cleaned) }
            hermesTurn = turn
            await turn.value
            if hermesTurn == turn { hermesTurn = nil }
            return
        }
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
        turnPeakLevel = max(turnPeakLevel, level)
        let result = turnDetector.observe(level: level, at: ProcessInfo.processInfo.systemUptime)
        switch result {
        case .listening:
            return
        case .finishTurn:
            guard let conversationSettings, let conversationID else { return }
            isCompletingTurn = true
            AgentTurnLog.note(String(format: "turn ended by silence; peak level %.2f", turnPeakLevel))
            Task { await stopAndProcess(settings: conversationSettings, conversationID: conversationID) }
        case .idleTimeout:
            isCompletingTurn = true
            AgentTurnLog.note(String(format: "idle timeout; peak level %.2f", turnPeakLevel))
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
        if wasActive { AgentTurnLog.note("conversation ended (announce: \(announce), phase: \(phase))") }
        let endingConversationID = conversationID
        conversationActive = false
        conversationID = nil
        conversationSettings = nil
        pendingRealtimeAction = nil
        pendingLocalAction = nil
        hermesTurn?.cancel()
        hermesTurn = nil
        abandonRelayQueue()
        announcementSink = nil
        hermesConfiguration = nil
        usesHermes = false
        activity = nil
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
        messages.append(VoiceAgentMessage(role: .milestone, text: "Conversation ended"))
    }

    private func discardCurrentRecording() {
        _ = recorder.stop()
        elapsedTask?.cancel()
        elapsedTask = nil
        audioLevel = 0
        isCompletingTurn = false
    }

    // MARK: - Relaying the live call to Hermes

    /// Answers the voice model's one tool. "Confirm" and "cancel" for an
    /// action on screen are settled here; everything else goes to Hermes.
    private func answerFunctionCall(_ name: String, _ arguments: [String: Any]) async -> RealtimeFunctionResult {
        guard name == HermesVoiceRelay.toolName else {
            return RealtimeFunctionResult(output: "That tool is not available.", speak: true)
        }
        guard let request = HermesVoiceRelay.request(from: arguments) else {
            return RealtimeFunctionResult(output: HermesVoiceRelay.failureOutput("nothing was said"), speak: true)
        }
        if pendingRealtimeAction != nil, let decision = VoiceAgentApprovalDecision(spoken: request) {
            switch decision {
            case .confirm:
                return RealtimeFunctionResult(output: await executeConfirmedRealtimeAction(), speak: true)
            case .cancel:
                pendingRealtimeAction = nil
                messages.append(VoiceAgentMessage(role: .hermes, text: "Cancelled. Nothing was opened or shared."))
                return RealtimeFunctionResult(
                    output: "Cancelled. Nothing was sent, saved, or opened. Tell the user in a few words.",
                    speak: true
                )
            }
        }
        return await withCheckedContinuation { continuation in
            relayQueue.append(RelayWaiter(request: request, continuation: continuation))
            startRelayWorkerIfNeeded()
        }
    }

    /// Drains the queue one Hermes turn at a time. Everything that queued up
    /// while a turn was in flight goes out together as the next turn.
    private func startRelayWorkerIfNeeded() {
        guard relayWorker == nil else { return }
        relayWorker = Task { [weak self] in
            guard let self else { return }
            while !self.relayQueue.isEmpty, !Task.isCancelled {
                let batch = self.relayQueue
                self.relayQueue = []
                if batch.count > 1 { AgentTurnLog.note("coalescing \(batch.count) queued requests into one turn") }
                let output = await self.relayToHermes(batch.map(\.request).joined(separator: "\n"))
                for waiter in batch.dropLast() { waiter.continuation.resume(returning: .superseded) }
                batch.last?.continuation.resume(returning: RealtimeFunctionResult(output: output, speak: true))
            }
            self.relayWorker = nil
        }
    }

    /// Lets every waiting call go so nothing leaks when the call ends; the
    /// Realtime client discards results for a connection that is gone.
    private func abandonRelayQueue() {
        relayWorker?.cancel()
        relayWorker = nil
        let waiting = relayQueue
        relayQueue = []
        for waiter in waiting { waiter.continuation.resume(returning: .abandoned) }
    }

    /// One turn against the gateway, returned whole as the tool result: the
    /// voice model needs the complete reply before it can speak it.
    private func relayToHermes(_ request: String) async -> String {
        guard let configuration = hermesConfiguration, let expected = conversationID else {
            return HermesVoiceRelay.failureOutput("the conversation has ended")
        }
        phase = .thinking
        activity = nil
        let outcome = await streamHermes(request, configuration: configuration) { [weak self] in
            self?.conversationID == expected
        }
        guard conversationID == expected, !Task.isCancelled else {
            return HermesVoiceRelay.failureOutput("the conversation has ended")
        }
        if let failure = outcome.failure { return HermesVoiceRelay.failureOutput(failure) }

        let result = HermesVoiceRelay.toolOutput(fromReply: outcome.text)
        if let action = result.action?.retargetedEmail(to: emailDelivery) {
            pendingRealtimeAction = action
        }
        AgentTurnLog.note("relaying \(result.output.count) chars to the voice\(result.action == nil ? "" : " + an action to approve")")
        return result.output
    }

    private struct HermesTurnOutcome {
        var text = ""
        var failure: String?
    }

    /// One streamed turn against the gateway. Tool starts drive the activity
    /// label on screen — never the voice: progress belongs on the display,
    /// and the reply is the only thing worth hearing.
    private func streamHermes(
        _ request: String,
        configuration: HermesAgentClient.Configuration,
        imageDataURLs: [String] = [],
        stillCurrent: @escaping () -> Bool
    ) async -> HermesTurnOutcome {
        AgentTurnLog.note("hermes request → \(configuration.baseURL.host ?? "?"): \(request.prefix(80))")
        let requestedAt = Date()
        var outcome = HermesTurnOutcome()
        var streamed = ""
        var completedText: String?
        do {
            for try await event in hermesClient.reply(
                to: request,
                configuration: configuration,
                place: place.spokenDescription,
                imageDataURLs: imageDataURLs
            ) {
                guard stillCurrent() else {
                    outcome.failure = "the conversation has ended"
                    return outcome
                }
                switch event {
                case .created:
                    AgentTurnLog.note(String(format: "hermes stream opened after %.1fs", Date().timeIntervalSince(requestedAt)))
                case .toolStarted(let name, _):
                    AgentTurnLog.note("hermes tool: \(name)")
                    activity = Self.activityLabel(forTool: name)
                case .toolFinished:
                    activity = nil
                case .textDelta(let delta):
                    streamed += delta
                case .completed(_, let full):
                    AgentTurnLog.note(String(format: "hermes completed after %.1fs (%d chars)", Date().timeIntervalSince(requestedAt), full.count))
                    completedText = full
                case .failed(let message):
                    AgentTurnLog.note("hermes failed: \(message)")
                    outcome.failure = message
                }
            }
        } catch is CancellationError {
            AgentTurnLog.note("hermes request cancelled")
            outcome.failure = "the conversation has ended"
        } catch {
            AgentTurnLog.note("hermes transport error: \(error.localizedDescription)")
            outcome.failure = error.localizedDescription
        }
        activity = nil
        outcome.text = completedText ?? streamed
        return outcome
    }

    // MARK: - Typed messages and dictations

    /// Whether a typed message can go out right now: on a live call it joins
    /// the relay; otherwise Hermes must be idle and nothing awaiting approval.
    /// The fallback conversation (on-device voice) owns the session while it
    /// runs, so typing waits for it to end.
    var canAcceptTypedMessage: Bool {
        guard !isTypingTurn else { return false }
        if usesRealtime, conversationActive { return true }
        return !conversationActive && !isBusy && pendingAction == nil
    }

    /// A typed message. On a live call it joins the same relay as speech and
    /// the reply is spoken; otherwise it is a text turn shown on screen.
    /// `shown` is what the thread displays when the request itself carries
    /// framing meant for Hermes rather than the reader. Returns whether the
    /// message reached Hermes.
    @discardableResult
    func sendTypedMessage(
        _ text: String,
        settings: SharedState,
        milestone: String? = nil,
        shown: String? = nil,
        attachments: [AgentAttachment] = []
    ) async -> Bool {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty, !attachments.isEmpty { cleaned = "Take a look at what I attached." }
        guard !cleaned.isEmpty, canAcceptTypedMessage else { return false }
        var displayed = shown?.trimmingCharacters(in: .whitespacesAndNewlines) ?? cleaned
        if usesRealtime, conversationActive {
            if let milestone { messages.append(VoiceAgentMessage(role: .milestone, text: milestone)) }
            messages.append(VoiceAgentMessage(role: .person, text: displayed))
            persistTurn(displayed, role: .person)
            AgentTurnLog.note("typed message joins the live call")
            let result = await withCheckedContinuation { continuation in
                relayQueue.append(RelayWaiter(request: cleaned, continuation: continuation))
                startRelayWorkerIfNeeded()
            }
            if !result.delivered {
                messages.append(VoiceAgentMessage(role: .hermes, text: result.output))
                return false
            }
            if result.speak, usesRealtime, conversationActive {
                realtimeClient.say("The user typed a message and Hermes replied. Read the reply aloud as your own words: \(result.output)")
            }
            return true
        }
        // Build what Hermes receives: document text inlined under the file's
        // name, photos as image parts. The thread shows the thumbnails and
        // names, not the inlined contents.
        var request = cleaned
        var imageDataURLs: [String] = []
        var thumbnails: [UIImage] = []
        for attachment in attachments {
            switch attachment.payload {
            case .image(let image):
                if let dataURL = AgentAttachmentLoader.imageDataURL(for: image) {
                    imageDataURLs.append(dataURL)
                    thumbnails.append(image)
                }
            case .text(let content):
                request += "\n\nAttached file \"\(attachment.name)\":\n\(content)"
            }
        }
        let documentNames = attachments.filter { $0.previewImage == nil }.map(\.name)
        if !documentNames.isEmpty {
            displayed += "\n📎 " + documentNames.joined(separator: ", ")
        }

        if let milestone { messages.append(VoiceAgentMessage(role: .milestone, text: milestone)) }
        messages.append(VoiceAgentMessage(role: .person, text: displayed, images: thumbnails))
        return await textTurn(request, shown: displayed, settings: settings, imageDataURLs: imageDataURLs)
    }

    /// A dictation handed over from the dictation screen. Framed for Hermes
    /// as exactly that, and marked in the thread so it is clear where it
    /// came from and where it went.
    @discardableResult
    func sendDictation(_ text: String, settings: SharedState) async -> Bool {
        await sendTypedMessage(
            HermesDictationHandoff.request(for: text),
            settings: settings,
            milestone: HermesDictationHandoff.milestone,
            shown: text
        )
    }

    private func textTurn(
        _ request: String,
        shown: String,
        settings: SharedState,
        imageDataURLs: [String] = []
    ) async -> Bool {
        place.refresh()
        if textConfiguration == nil {
            let id = UUID()
            do {
                textConfiguration = try HermesAgentClient.configuration(
                    serverURL: settings.hermesServerURL,
                    conversationID: id,
                    model: settings.hermesVoiceModel
                )
            } catch {
                messages.append(VoiceAgentMessage(role: .hermes, text: error.localizedDescription))
                return false
            }
            textConversationID = id
            try? conversationStore.begin(id: id, mode: .hermes)
        }
        guard let configuration = textConfiguration, let id = textConversationID else { return false }
        try? conversationStore.append(shown, role: .person, to: id)
        refreshHistory()

        isTypingTurn = true
        phase = .thinking
        activity = nil
        let outcome = await streamHermes(request, configuration: configuration, imageDataURLs: imageDataURLs) { [weak self] in
            self?.textConversationID == id
        }
        isTypingTurn = false
        activity = nil
        phase = .ready

        if let failure = outcome.failure {
            messages.append(VoiceAgentMessage(role: .hermes, text: "Hermes couldn't answer: \(failure)"))
            return false
        }
        let parsed = HermesActionBlock.extract(from: outcome.text)
        let plain = SpokenText.plain(parsed.spoken).trimmingCharacters(in: .whitespacesAndNewlines)
        let reply = plain.isEmpty
            ? (parsed.action == nil ? "Hermes didn't say anything." : "Prepared something for you to approve.")
            : plain
        messages.append(VoiceAgentMessage(role: .hermes, text: reply))
        try? conversationStore.append(reply, role: .hermes, to: id)
        refreshHistory()
        if let action = parsed.action?.retargetedEmail(to: emailDelivery) {
            pendingRealtimeAction = action
        }
        return true
    }

    /// Carries out the action on screen after the user said "confirm", and
    /// returns what happened for the voice to say.
    private func executeConfirmedRealtimeAction() async -> String {
        guard let action = pendingRealtimeAction else {
            return "There was nothing waiting for approval. Tell the user."
        }
        pendingRealtimeAction = nil
        announcementSink = []
        await execute(action)
        let outcome = announcementSink?.joined(separator: " ") ?? ""
        announcementSink = nil
        return "\(outcome.isEmpty ? "Done; the phone is showing it now." : outcome) Tell the user in a few words."
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
            await openDestination(app: "googlegmail://", web: "https://mail.google.com/", name: "Gmail")
        case .open(.appSettings):
            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
            await open(url, failureMessage: "I couldn't open Settings.")
        case .open(.maps):
            await openDestination(app: "maps://", web: "https://maps.apple.com/", name: "Maps")
        case .open(.calendar):
            await openDestination(app: "calshow://", web: nil, name: "Calendar")
        case .open(.music):
            await openDestination(app: "music://", web: nil, name: "Music")
        case .open(.youtube):
            await openDestination(app: "youtube://", web: "https://www.youtube.com/", name: "YouTube")
        case .open(.spotify):
            await openDestination(app: "spotify://", web: "https://open.spotify.com/", name: "Spotify")
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

    /// Opens the destination's own app when it is installed, and only falls
    /// back to the web when it is not: landing in Safari while the app sits on
    /// the home screen is a detour, not a shortcut. The schemes are declared
    /// in LSApplicationQueriesSchemes so canOpenURL can answer honestly.
    private func openDestination(app appValue: String, web webValue: String?, name: String) async {
        if let appURL = URL(string: appValue), UIApplication.shared.canOpenURL(appURL) {
            if await UIApplication.shared.open(appURL) { return }
        }
        guard let webValue, let webURL = URL(string: webValue) else {
            await reportHandoffFailure("I couldn't open \(name) on this iPhone.")
            return
        }
        await open(webURL, failureMessage: "I couldn't open \(name) on this iPhone.")
    }

    private func handleRealtimeState(_ state: RealtimeAgentClient.State) {
        guard usesRealtime || state == .connecting else { return }
        switch state {
        case .disconnected:
            if conversationActive {
                AgentTurnLog.note("live conversation disconnected")
                phase = .failed("The live conversation disconnected. Tap to reconnect.")
            }
        case .connecting:
            phase = .connecting
        case .listening:
            phase = .recording
        case .responding:
            phase = .speaking
        case .failed(let message):
            AgentTurnLog.note("live conversation failed: \(message)")
            if let conversationID { try? conversationStore.end(id: conversationID) }
            realtimeClient.stop()
            abandonRelayQueue()
            announcementSink = nil
            hermesConfiguration = nil
            pendingRealtimeAction = nil
            phase = .failed(message)
            conversationActive = false
            usesRealtime = false
            conversationID = nil
            conversationSettings = nil
            refreshHistory()
        }
    }

    private func handleRealtimeUserTranscript(_ transcript: String) {
        appendRealtimeMessage(role: .person, text: transcript)
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

    func forgetMemory(id: UUID) {
        try? memoryStore.delete(id: id)
        memories = memoryStore.memories
    }

    func forgetEverything() {
        try? memoryStore.clear()
        memories = memoryStore.memories
    }

    /// Removes one saved conversation. The live thread on screen is left alone:
    /// deleting yesterday's transcript should not blank out what is being said
    /// right now.
    func deleteConversation(id: UUID) {
        try? conversationStore.delete(id: id)
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

    private func open(_ url: URL, failureMessage: String) async {
        let opened = await UIApplication.shared.open(url)
        if !opened {
            await reportHandoffFailure(failureMessage)
        }
    }

    private func announce(_ message: String) async {
        messages.append(VoiceAgentMessage(role: .hermes, text: message))
        if announcementSink != nil {
            announcementSink?.append(message)
            return
        }
        if usesRealtime, conversationActive {
            realtimeClient.say("Tell the user in a few words: \(message)")
            return
        }
        phase = .speaking
        await speaker.speak(message)
        phase = .ready
    }

    private func reportHandoffFailure(_ message: String) async {
        messages.append(VoiceAgentMessage(role: .hermes, text: message))
        if announcementSink != nil {
            announcementSink?.append(message)
            return
        }
        if usesRealtime, conversationActive {
            realtimeClient.say("Tell the user in a few words that this failed: \(message)")
            return
        }
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

    /// Utterances queued behind the current one, for replies spoken as they
    /// stream in.
    private var queuedCount = 0
    private var drainContinuation: CheckedContinuation<Void, Never>?

    func speak(_ text: String) async {
        stop()
        prepareAudioSession()
        let utterance = makeUtterance(text)
        self.utterance = utterance

        await withCheckedContinuation { continuation in
            self.continuation = continuation
            synthesizer.speak(utterance)
        }
    }

    /// Says `text` after whatever is already queued, without interrupting it.
    func enqueue(_ text: String) {
        if queuedCount == 0, utterance == nil { prepareAudioSession() }
        queuedCount += 1
        synthesizer.speak(makeUtterance(text))
    }

    /// Waits until everything queued with `enqueue` has been said.
    func finishSpeaking() async {
        guard queuedCount > 0 else { return }
        await withCheckedContinuation { drainContinuation = $0 }
    }

    private func prepareAudioSession() {
        do {
            try audioSession.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try audioSession.setActive(true)
        } catch {
            AgentTurnLog.note("speech audio setup failed: \(error.localizedDescription)")
        }
    }

    private func makeUtterance(_ text: String) -> AVSpeechUtterance {
        let utterance = AVSpeechUtterance(string: text)
        let language = Locale.current.identifier.replacingOccurrences(of: "_", with: "-")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.92
        utterance.pitchMultiplier = 0.98
        utterance.voice = Self.preferredVoice(for: language)
        return utterance
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
        queuedCount = 0
        drainContinuation?.resume()
        drainContinuation = nil
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
        if utterance === completedUtterance {
            utterance = nil
            continuation?.resume()
            continuation = nil
        } else if queuedCount > 0 {
            queuedCount -= 1
            if queuedCount == 0 {
                drainContinuation?.resume()
                drainContinuation = nil
            }
        } else {
            return
        }
        guard utterance == nil, queuedCount == 0 else { return }
        try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
    }
}
