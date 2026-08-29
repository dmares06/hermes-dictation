import SwiftUI
import UIKit

struct VoiceAgentView: View {
    @Environment(SharedState.self) private var settings
    let controller: VoiceAgentController
    let downloadService: ModelDownloadService
    @State private var isAtBottom = true

    var body: some View {
        @Bindable var controller = controller

        NavigationStack {
            VStack(spacing: 0) {
                transcript
                Divider()
                MessageComposer(controller: controller, settings: settings)
                AgentRecordingCard(
                    controller: controller,
                    modelReady: downloadService.isPrepared,
                    color: settings.recordButtonColor,
                    action: { Task { await controller.performPrimaryAction(settings: settings) } },
                    startFallback: { Task { await controller.startHermesConversation(settings: settings) } },
                    endConversation: { Task { await controller.endConversation() } }
                )
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Hermes Agent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        settings.agentUsesSpeaker.toggle()
                        controller.usesSpeaker = settings.agentUsesSpeaker
                    } label: {
                        Label(
                            settings.agentUsesSpeaker ? "Speaker on" : "Speaker off",
                            systemImage: settings.agentUsesSpeaker ? "speaker.wave.2.fill" : "ear"
                        )
                    }
                    .accessibilityHint(
                        settings.agentUsesSpeaker
                            ? "Hermes plays through the speaker. Tap to use the earpiece."
                            : "Hermes plays through the earpiece. Tap to use the speaker."
                    )
                }
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(destination: AgentHistoryView(controller: controller)) {
                        Label("Memory", systemImage: "brain.head.profile")
                    }
                    .accessibilityHint("Review what Hermes remembers, and past conversations")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(destination: SettingsView()) {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
            }
            .onAppear { controller.usesSpeaker = settings.agentUsesSpeaker }
            .alert("Microphone access needed", isPresented: $controller.showsMicrophoneSettings) {
                Button("Open Settings", action: controller.openAppSettings)
                Button("Not now", role: .cancel) {}
            } message: {
                Text("Turn on Microphone access for WhisperDict, then return here to talk to Hermes.")
            }
            .sheet(item: $controller.sharePayload) { payload in
                ActivityView(items: [payload.text])
            }
            .sheet(item: $controller.messagePayload) { payload in
                MessageComposeView(body: payload.body, recipients: payload.recipients)
            }
        }
    }

    /// The thread lives in its own scroll view, with the controls pinned
    /// outside it. Sharing one scroll view meant every change in the controls —
    /// the timer ticking, a spinner swapping for an icon, a button appearing —
    /// resized the content and shoved the transcript around while it was being
    /// read.
    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    if showsIntroduction {
                        AgentBoundaryCard()
                    }

                    ForEach(controller.messages) { message in
                        entry(for: message).id(message.id)
                    }

                    // Below the thread, not above it: these are disabled while
                    // a conversation is running, so they belong where they are
                    // reachable when idle without pushing the transcript down.
                    if !controller.conversationActive {
                        QuickRequests(controller: controller)
                    }

                    if let action = controller.pendingAction {
                        PendingActionCard(
                            action: action,
                            confirm: { Task { await controller.confirmPending() } },
                            cancel: { Task { await controller.cancelPending() } }
                        )
                        .id(Self.pendingActionID)
                    }

                    if !downloadService.isPrepared && !controller.usesRealtime {
                        AgentModelCard(service: downloadService, model: settings.modelSize)
                    }

                    // A sentinel rather than a scroll-offset reading: it is on
                    // screen exactly when the end of the thread is, which is the
                    // question being asked.
                    Color.clear
                        .frame(height: 1)
                        .onAppear { isAtBottom = true }
                        .onDisappear { isAtBottom = false }
                }
                .padding()
            }
            .onChange(of: controller.messages.count) { _, _ in
                // Follow the thread only while the reader is already at the end,
                // so scrolling back to re-read something is never interrupted by
                // the next thing either of you says.
                guard isAtBottom, let last = controller.messages.last else { return }
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last.id, anchor: .bottom) }
            }
            .onChange(of: controller.pendingAction != nil) { _, isPending in
                // An action waiting on approval is the one thing worth taking
                // the reader away from where they were: nothing else moves until
                // they answer it.
                guard isPending else { return }
                withAnimation { proxy.scrollTo(Self.pendingActionID, anchor: .bottom) }
            }
        }
    }

    private static let pendingActionID = "pending-action"

    /// The opening card is for someone who has not started yet. Once there is a
    /// thread to read it would only be padding above it.
    private var showsIntroduction: Bool {
        !controller.conversationActive && controller.messages.count <= 1
    }

    @ViewBuilder
    private func entry(for message: VoiceAgentMessage) -> some View {
        switch message.role {
        case .milestone:
            TranscriptStamp(date: message.createdAt, note: message.text)
        case .person, .hermes:
            TranscriptBubble(text: message.text, isPerson: message.role == .person)
        }
    }
}

/// A centred date separator, the way Messages breaks up a thread.
private struct TranscriptStamp: View {
    let date: Date
    let note: String

    var body: some View {
        VStack(spacing: 1) {
            Text(Self.stamp(for: date))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            if !note.isEmpty {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    /// "Today 1:04 PM", "Yesterday 1:04 PM", "Wednesday 1:04 PM", then the date.
    static func stamp(for date: Date, now: Date = Date()) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today \(time)" }
        if calendar.isDateInYesterday(date) { return "Yesterday \(time)" }
        if let days = calendar.dateComponents([.day], from: date, to: now).day, days < 7 {
            return "\(date.formatted(.dateTime.weekday(.wide))) \(time)"
        }
        return "\(date.formatted(date: .abbreviated, time: .omitted)) \(time)"
    }
}

private struct TranscriptBubble: View {
    let text: String
    let isPerson: Bool

    var body: some View {
        HStack(spacing: 0) {
            if isPerson { Spacer(minLength: 52) }
            Text(text)
                .font(.body)
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(
                    isPerson ? Color.mint.opacity(0.28) : Color(uiColor: .secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 19, style: .continuous)
                )
            if !isPerson { Spacer(minLength: 52) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(isPerson ? "You" : "Hermes"): \(text)")
    }
}

private struct AgentBoundaryCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("You stay in control", systemImage: "checkmark.shield")
                .font(.headline)
                .foregroundStyle(.mint)
            Text("Tap once to start a live conversation. Hermes listens for the end of each turn, answers aloud, and listens again. External actions still wait for your confirmation.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 18))
    }
}

private struct AgentRecordingCard: View {
    let controller: VoiceAgentController
    let modelReady: Bool
    let color: AppearanceColor
    let action: () -> Void
    /// Hermes with the phone's own transcription and voice, for when the
    /// live audio session cannot be set up.
    let startFallback: () -> Void
    let endConversation: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Text(controller.statusText)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(statusColor)
                .multilineTextAlignment(.center)

            if controller.conversationActive {
                Text(String(format: "%02d:%02d", controller.elapsedSeconds / 60, controller.elapsedSeconds % 60))
                    .font(.system(.subheadline, design: .monospaced, weight: .medium))
                    .foregroundStyle(.secondary)
                AgentLevelMeter(level: controller.audioLevel, active: controller.isRecording)
            }

            Button(action: action) {
                ZStack {
                    Circle()
                        .fill(buttonColor)
                        .frame(width: 78, height: 78)
                        .shadow(color: buttonColor.opacity(0.25), radius: 14, y: 6)
                    if controller.isBusy && !(controller.usesRealtime && controller.conversationActive) {
                        ProgressView().tint(buttonForeground).scaleEffect(1.3)
                    } else {
                        Image(systemName: primaryIcon)
                            .font(.system(size: 29, weight: .semibold))
                            .foregroundStyle(buttonForeground)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(controller.primaryAction == .wait)
            .accessibilityLabel(primaryAccessibilityLabel)
            .accessibilityHint(primaryAccessibilityHint)

            if controller.conversationActive && !controller.usesRealtime {
                Button("End conversation", role: .destructive, action: endConversation)
                    .buttonStyle(.bordered)
                    .accessibilityHint("Ends the conversation without sending an unfinished recording")
            }

            if controller.canUseOfflineMode {
                Button("Use slower voice", action: startFallback)
                    .buttonStyle(.bordered)
                    .accessibilityHint("Talks to Hermes with transcription on this iPhone and the system voice instead of live audio")
            }

            Text(instructionText)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 12)
        .padding(.bottom, 6)
        .padding(.horizontal)
        .background(.bar)
    }

    private var statusColor: Color {
        if case .failed = controller.phase { return .red }
        return controller.conversationActive ? .red : .primary
    }

    private var buttonColor: Color {
        controller.conversationActive ? .red : Color(appearanceColor: color)
    }

    private var buttonForeground: Color {
        guard !controller.conversationActive, color.prefersDarkForeground else { return .white }
        return .black
    }

    private var instructionText: String {
        guard controller.conversationActive else {
            return modelReady
                ? "Tap once to talk to Hermes"
                : "Tap once to talk to Hermes. Prepare the speech model in Dictation for the slower fallback."
        }
        switch controller.phase {
        case .connecting: return "Creating a secure live audio session…"
        case .recording:
            return controller.usesRealtime
                ? "Speak naturally. You can interrupt Hermes; tap the red button to end."
                : "Pause when finished, or tap the checkmark to send this turn now"
        case .transcribing: return "Understanding your request…"
        case .thinking: return "Hermes is working on it…"
        case .speaking: return "Hermes will listen again after speaking"
        case .ready: return "Getting ready to listen again…"
        case .failed: return "End the conversation, then try again"
        }
    }

    private var primaryIcon: String {
        if controller.usesRealtime && controller.conversationActive { return "phone.down.fill" }
        return controller.isRecording ? "checkmark" : "waveform.and.mic"
    }

    private var primaryAccessibilityLabel: String {
        if controller.usesRealtime && controller.conversationActive { return "End live conversation" }
        return controller.isRecording ? "Finish speaking" : "Start conversation"
    }

    private var primaryAccessibilityHint: String {
        if controller.usesRealtime && controller.conversationActive {
            return "Disconnects the Realtime voice conversation"
        }
        return controller.isRecording
            ? "Stops this recording and sends it to Hermes"
            : "Starts private hands-free turn taking with Hermes"
    }
}

private struct HermesUsageCard: View {
    let summary: HermesUsageSummary

    var body: some View {
        HStack(spacing: 8) {
            metric("Conversations", value: summary.conversationCount)
            Divider()
            metric("Words spoken", value: summary.spokenWordCount)
            Divider()
            metric("Words captured", value: summary.totalCapturedWordCount)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 18))
        .accessibilityElement(children: .combine)
    }

    private func metric(_ title: String, value: Int) -> some View {
        VStack(spacing: 4) {
            Text(value.formatted())
                .font(.headline.monospacedDigit())
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }
}

private enum AgentArchiveTab: Hashable {
    case remembered
    case conversations
}

struct AgentHistoryView: View {
    let controller: VoiceAgentController
    @State private var tab: AgentArchiveTab = .remembered
    @State private var showsClearConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            Picker("Show", selection: $tab) {
                Text("Remembered").tag(AgentArchiveTab.remembered)
                Text("Conversations").tag(AgentArchiveTab.conversations)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.bottom, 8)

            switch tab {
            case .remembered: rememberedList
            case .conversations: conversationList
            }
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("Hermes memory")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if canClear {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Clear", role: .destructive) { showsClearConfirmation = true }
                }
            }
        }
        .confirmationDialog(clearTitle, isPresented: $showsClearConfirmation, titleVisibility: .visible) {
            Button("Delete all", role: .destructive, action: clearVisible)
            Button("Keep", role: .cancel) {}
        } message: {
            Text("This cannot be undone.")
        }
    }

    // MARK: What Hermes knows

    private var rememberedList: some View {
        Group {
            if controller.memories.isEmpty {
                ContentUnavailableView(
                    "Nothing remembered yet",
                    systemImage: "brain.head.profile",
                    description: Text("Tell Hermes something lasting about yourself during a conversation and it will keep it here.")
                )
            } else {
                List {
                    ForEach(HermesMemoryKind.allCases) { kind in
                        if !remembered(ofKind: kind).isEmpty {
                            Section {
                                ForEach(remembered(ofKind: kind)) { memory in
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(memory.text)
                                            .font(.subheadline)
                                        Text(TranscriptStamp.stamp(for: memory.updatedAt))
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                    }
                                    .padding(.vertical, 2)
                                }
                                .onDelete { forget(offsets: $0, in: kind) }
                            } header: {
                                Label(kind.title, systemImage: kind.symbolName)
                            }
                        }
                    }

                    Section {
                    } footer: {
                        Text("These are stored on this iPhone and sent to Hermes as context at the start of each conversation. Delete one and it stops being sent.")
                    }
                }
            }
        }
    }

    private func remembered(ofKind kind: HermesMemoryKind) -> [HermesMemory] {
        controller.memories.filter { $0.kind == kind }
    }

    /// Offsets are into the section's own filtered list, so they are resolved
    /// against that same list before anything is removed.
    private func forget(offsets: IndexSet, in kind: HermesMemoryKind) {
        let section = remembered(ofKind: kind)
        for id in offsets.map({ section[$0].id }) { controller.forgetMemory(id: id) }
    }

    // MARK: Past conversations

    private var conversationList: some View {
        Group {
            if controller.conversationHistory.isEmpty {
                ContentUnavailableView(
                    "No conversations yet",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Conversations you have with Hermes are saved here when they end.")
                )
            } else {
                List {
                    Section {
                        HermesUsageCard(summary: controller.usageSummary)
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                    }

                    Section("Conversations") {
                        ForEach(controller.conversationHistory) { conversation in
                            NavigationLink {
                                AgentConversationDetail(conversation: conversation)
                            } label: {
                                AgentHistoryRow(conversation: conversation)
                            }
                        }
                        .onDelete(perform: delete)
                    }
                }
            }
        }
    }

    /// Resolve the offsets to identifiers first: each delete rewrites the list
    /// the offsets came from, so a second index would point at the wrong row.
    private func delete(at offsets: IndexSet) {
        let doomed = offsets.map { controller.conversationHistory[$0].id }
        for id in doomed { controller.deleteConversation(id: id) }
    }

    // MARK: Clearing

    private var canClear: Bool {
        switch tab {
        case .remembered: !controller.memories.isEmpty
        case .conversations: !controller.conversationHistory.isEmpty
        }
    }

    private var clearTitle: String {
        switch tab {
        case .remembered: "Forget everything Hermes has remembered?"
        case .conversations: "Delete every saved conversation?"
        }
    }

    private func clearVisible() {
        switch tab {
        case .remembered: controller.forgetEverything()
        case .conversations: controller.clearConversationHistory()
        }
    }
}

private struct AgentHistoryRow: View {
    let conversation: HermesConversation

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(TranscriptStamp.stamp(for: conversation.startedAt))
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 8)
                Text(conversation.mode.label)
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color.mint.opacity(0.22), in: Capsule())
            }
            Text(conversation.turns.last?.text ?? "No spoken turns")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }

    private var detail: String {
        let turns = "\(conversation.turns.count) turn\(conversation.turns.count == 1 ? "" : "s")"
        guard let endedAt = conversation.endedAt else { return turns }
        let seconds = max(0, Int(endedAt.timeIntervalSince(conversation.startedAt)))
        return "\(turns) · \(seconds / 60)m \(seconds % 60)s"
    }
}

private struct AgentConversationDetail: View {
    let conversation: HermesConversation

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                TranscriptStamp(
                    date: conversation.startedAt,
                    note: "\(conversation.mode.label) conversation"
                )

                ForEach(conversation.turns) { turn in
                    TranscriptBubble(text: turn.text, isPerson: turn.role == .person)
                }

                if conversation.turns.isEmpty {
                    Text("This conversation ended before anything was said.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if let endedAt = conversation.endedAt {
                    TranscriptStamp(date: endedAt, note: "Conversation ended")
                }
            }
            .padding()
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(TranscriptStamp.stamp(for: conversation.startedAt))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: shareText) { Label("Share", systemImage: "square.and.arrow.up") }
                    .disabled(conversation.turns.isEmpty)
            }
        }
    }

    private var shareText: String {
        conversation.turns
            .map { "\($0.role == .person ? "You" : "Hermes"): \($0.text)" }
            .joined(separator: "\n\n")
    }
}

private extension HermesConversationMode {
    var label: String {
        switch self {
        case .realtime: "Live"
        case .offline: "Offline"
        case .hermes: "Hermes"
        }
    }
}

private struct AgentLevelMeter: View {
    let level: Float
    let active: Bool

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<13, id: \.self) { index in
                Capsule()
                    .fill(active && Float(index) / 13 < level ? .red : .secondary.opacity(0.25))
                    .frame(width: 5, height: height(index))
            }
        }
        .frame(height: 30)
        .accessibilityHidden(true)
    }

    private func height(_ index: Int) -> CGFloat {
        guard active else { return 5 }
        let distance = abs(index - 6)
        let shape = max(0.3, 1 - Float(distance) * 0.09)
        return CGFloat(5 + 25 * min(1, level * 1.8) * shape)
    }
}

private struct PendingActionCard: View {
    let action: VoiceAgentAction
    let confirm: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Waiting for your approval", systemImage: "hand.raised.fill")
                .font(.headline)
                .foregroundStyle(.orange)
            Divider()
            actionDetails
            HStack {
                Button("Cancel", role: .cancel, action: cancel)
                    .buttonStyle(.bordered)
                Spacer()
                Button(confirmTitle, systemImage: "arrow.up.forward.app", action: confirm)
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.orange.opacity(0.35)))
    }

    @ViewBuilder
    private var actionDetails: some View {
        switch action {
        case .composeEmail(let draft), .sendEmail(let draft):
            detail("To", draft.recipient)
            detail("Subject", draft.subject)
            detail("Body", draft.body)
        case .shareNote(let text):
            detail("Note", text)
        case .saveNote(let text):
            detail("Note", text)
        case .createReminder(let draft):
            detail("Reminder", draft.title)
            detail("When", draft.dueDate?.formatted(date: .abbreviated, time: .shortened) ?? "No time")
        case .composeMessage(let text):
            detail("Message", text)
        case .open(.gmailWeb):
            detail("Destination", "Gmail in your browser")
        case .open(.appSettings):
            detail("Destination", "WhisperDict Settings")
        case .open(.maps):
            detail("Destination", "Apple Maps")
        case .open(.calendar):
            detail("Destination", "Calendar")
        case .open(.music):
            detail("Destination", "Apple Music")
        case .open(.youtube):
            detail("Destination", "YouTube")
        case .open(.spotify):
            detail("Destination", "Spotify")
        case .runShortcut(let name):
            detail("Shortcut", name)
        }
    }

    private func detail(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }

    private var confirmTitle: String {
        switch action {
        case .composeEmail: "Open email draft"
        case .sendEmail: "Send with Gmail"
        case .shareNote: "Share note"
        case .saveNote: "Save note"
        case .createReminder: "Add reminder"
        case .composeMessage: "Open message draft"
        case .open(.gmailWeb): "Open Gmail"
        case .open(.appSettings): "Open Settings"
        case .open(.maps): "Open Maps"
        case .open(.calendar): "Open Calendar"
        case .open(.music): "Open Music"
        case .open(.youtube): "Open YouTube"
        case .open(.spotify): "Open Spotify"
        case .runShortcut: "Run Shortcut"
        }
    }
}

/// Type instead of talk — a meeting, a noisy room, a card number nobody
/// should hear. Same Hermes, same session as the voice.
private struct MessageComposer: View {
    let controller: VoiceAgentController
    let settings: SharedState
    @State private var draft = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            TextField("Message Hermes", text: $draft)
                .textFieldStyle(.roundedBorder)
                .submitLabel(.send)
                .focused($isFocused)
                .onSubmit(send)
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title)
                    .foregroundStyle(canSend ? Color.mint : Color.secondary)
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .accessibilityLabel("Send to Hermes")
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && controller.canAcceptTypedMessage
    }

    /// The draft is cleared only once the controller has taken it, so a
    /// message can never vanish from the field without being sent.
    private func send() {
        guard canSend else { return }
        let text = draft
        draft = ""
        Task {
            if await !controller.sendTypedMessage(text, settings: settings), draft.isEmpty {
                draft = text
            }
        }
    }
}

private struct QuickRequests: View {
    let controller: VoiceAgentController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Try a request").font(.headline)
            ViewThatFits(in: .horizontal) {
                HStack {
                    buttons
                }
                VStack(alignment: .leading) {
                    buttons
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 18))
    }

    @ViewBuilder
    private var buttons: some View {
        quickButton("Compose email", request: "Compose an email")
        quickButton("Create note", request: "Create a note")
        quickButton("Send message", request: "Send a message")
        quickButton("Open Gmail", request: "Open Gmail")
        quickButton("Open Maps", request: "Open Maps")
    }

    private func quickButton(_ title: String, request: String) -> some View {
        Button(title) { Task { await controller.submitText(request) } }
            .buttonStyle(.bordered)
            .disabled(
                controller.isRecording
                    || controller.conversationActive
                    || controller.isBusy
                    || controller.pendingAction != nil
                    || controller.session.step != .idle
            )
    }
}

private struct AgentModelCard: View {
    let service: ModelDownloadService
    let model: ModelSize

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Prepare offline fallback", systemImage: "arrow.down.circle")
                .font(.headline)
            Text("Optional offline fallback: Hermes can use the private on-device \(model.title) model when Realtime is unavailable.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if service.isPreparing {
                ProgressView(value: service.progress)
                Text("Downloading… \(Int(service.progress * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Button("Prepare model") { Task { await service.prepare(model: model) } }
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 18))
    }
}

private struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

#Preview {
    VoiceAgentView(controller: VoiceAgentController(), downloadService: ModelDownloadService())
        .environment(SharedState(defaults: .standard))
}
