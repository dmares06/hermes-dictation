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
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 16) {
                        AgentBoundaryCard()
                        HermesUsageCard(summary: controller.usageSummary)
                        conversation

                        if let action = controller.pendingAction {
                            PendingActionCard(
                                action: action,
                                confirm: { Task { await controller.confirmPending() } },
                                cancel: { Task { await controller.cancelPending() } }
                            )
                        }

                        if !downloadService.isPrepared && !controller.usesRealtime {
                            AgentModelCard(service: downloadService, model: settings.modelSize)
                        }

                        AgentRecordingCard(
                            controller: controller,
                            modelReady: downloadService.isPrepared,
                            color: settings.recordButtonColor,
                            action: { Task { await controller.performPrimaryAction(settings: settings) } },
                            startOffline: { Task { await controller.startOfflineConversation(settings: settings) } },
                            endConversation: { Task { await controller.endConversation() } }
                        )

                        QuickRequests(controller: controller)

                        if !controller.conversationHistory.isEmpty {
                            AgentHistoryCard(
                                conversations: controller.conversationHistory,
                                clear: controller.clearConversationHistory
                            )
                        }

                        // A sentinel rather than a scroll-offset reading: it is
                        // on screen exactly when the end of the feed is, which
                        // is the question being asked.
                        Color.clear
                            .frame(height: 1)
                            .onAppear { isAtBottom = true }
                            .onDisappear { isAtBottom = false }
                    }
                    .padding()
                }
                .background(Color(uiColor: .systemGroupedBackground))
                .onChange(of: controller.messages.count) { _, _ in
                    // Follow the conversation only while the reader is already
                    // at the end. Yanking the view down mid-sentence is what
                    // makes it impossible to scroll back and read anything.
                    guard isAtBottom, let last = controller.messages.last else { return }
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            .navigationTitle("Hermes Agent")
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

    private var conversation: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(controller.messages) { message in
                HStack {
                    if message.role == .person { Spacer(minLength: 42) }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(message.role == .person ? "You" : "Hermes")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(message.text)
                            .font(.body)
                            .textSelection(.enabled)
                    }
                    .padding(12)
                    .background(
                        message.role == .person ? Color.mint.opacity(0.18) : Color(uiColor: .secondarySystemBackground),
                        in: RoundedRectangle(cornerRadius: 15)
                    )
                    if message.role == .hermes { Spacer(minLength: 42) }
                }
                .id(message.id)
            }
        }
        .frame(maxWidth: .infinity)
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
    let startOffline: () -> Void
    let endConversation: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Text(controller.statusText)
                .font(.headline)
                .foregroundStyle(statusColor)
                .multilineTextAlignment(.center)

            if controller.conversationActive {
                Text(String(format: "%02d:%02d", controller.elapsedSeconds / 60, controller.elapsedSeconds % 60))
                    .font(.system(.title3, design: .monospaced, weight: .medium))
            } else {
                Text(modelReady ? "One tap starts hands-free turn taking." : "Prepare the model to begin.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            AgentLevelMeter(level: controller.audioLevel, active: controller.isRecording)

            Button(action: action) {
                ZStack {
                    Circle()
                        .fill(buttonColor)
                        .frame(width: 96, height: 96)
                        .shadow(color: buttonColor.opacity(0.25), radius: 16, y: 7)
                    if controller.isBusy && !(controller.usesRealtime && controller.conversationActive) {
                        ProgressView().tint(buttonForeground).scaleEffect(1.3)
                    } else {
                        Image(systemName: primaryIcon)
                            .font(.system(size: 34, weight: .semibold))
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
                Button("Use slower offline voice", action: startOffline)
                    .buttonStyle(.bordered)
                    .accessibilityHint("Starts local transcription and the iPhone system voice instead of Realtime audio")
            }

            Text(instructionText)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .padding(.horizontal)
        .background(.background, in: RoundedRectangle(cornerRadius: 22))
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
            return "Tap once for a low-latency, natural voice conversation"
        }
        switch controller.phase {
        case .connecting: return "Creating a secure live audio session…"
        case .recording:
            return controller.usesRealtime
                ? "Speak naturally. You can interrupt Hermes; tap the red button to end."
                : "Pause when finished, or tap the checkmark to send this turn now"
        case .transcribing: return "Understanding your request…"
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

private struct AgentHistoryCard: View {
    let conversations: [HermesConversation]
    let clear: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Conversation history", systemImage: "clock.arrow.circlepath")
                    .font(.headline)
                Spacer()
                Button("Clear", role: .destructive, action: clear)
                    .font(.caption)
            }

            ForEach(Array(conversations.prefix(5))) { conversation in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(conversation.startedAt, style: .relative)
                            .font(.caption.weight(.semibold))
                        Spacer()
                        Text(conversation.mode == .realtime ? "Realtime" : "Offline")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Text(conversation.turns.last?.text ?? "No spoken turns")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if conversation.id != conversations.prefix(5).last?.id { Divider() }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 18))
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
