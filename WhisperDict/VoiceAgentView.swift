import SwiftUI
import UIKit

struct VoiceAgentView: View {
    @Environment(SharedState.self) private var settings
    let controller: VoiceAgentController
    let downloadService: ModelDownloadService

    var body: some View {
        @Bindable var controller = controller

        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 16) {
                        AgentBoundaryCard()
                        conversation

                        if let action = controller.pendingAction {
                            PendingActionCard(
                                action: action,
                                confirm: { Task { await controller.confirmPending() } },
                                cancel: { Task { await controller.cancelPending() } }
                            )
                        }

                        if !downloadService.isPrepared {
                            AgentModelCard(service: downloadService, model: settings.modelSize)
                        }

                        AgentRecordingCard(
                            controller: controller,
                            modelReady: downloadService.isPrepared,
                            color: settings.recordButtonColor,
                            action: { Task { await controller.toggleConversation(settings: settings) } }
                        )

                        QuickRequests(controller: controller)
                    }
                    .padding()
                }
                .background(Color(uiColor: .systemGroupedBackground))
                .onChange(of: controller.messages.count) { _, _ in
                    guard let last = controller.messages.last else { return }
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            .navigationTitle("Hermes Agent")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(destination: SettingsView()) {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
            }
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
                MessageComposeView(body: payload.body)
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
                    if controller.isBusy && !controller.conversationActive {
                        ProgressView().tint(buttonForeground).scaleEffect(1.3)
                    } else {
                        Image(systemName: controller.conversationActive ? "stop.fill" : "waveform.and.mic")
                            .font(.system(size: 34, weight: .semibold))
                            .foregroundStyle(buttonForeground)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(!modelReady && !controller.conversationActive)
            .accessibilityLabel(controller.conversationActive ? "End conversation" : "Start conversation")
            .accessibilityHint("Starts or ends private hands-free turn taking with Hermes")

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
            return "Tap once, speak naturally, and Hermes will keep the conversation going"
        }
        switch controller.phase {
        case .recording: return "Listening now — pause when your turn is finished"
        case .transcribing: return "Understanding your request…"
        case .speaking: return "Hermes will listen again after speaking"
        case .ready: return "Getting ready to listen again…"
        case .failed: return "Tap Stop, then start a new conversation"
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
        case .composeEmail(let draft):
            detail("To", draft.recipient)
            detail("Subject", draft.subject)
            detail("Body", draft.body)
        case .shareNote(let text):
            detail("Note", text)
        case .composeMessage(let text):
            detail("Message", text)
        case .open(.gmailWeb):
            detail("Destination", "Gmail in your browser")
        case .open(.appSettings):
            detail("Destination", "WhisperDict Settings")
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
        case .shareNote: "Share note"
        case .composeMessage: "Open message draft"
        case .open(.gmailWeb): "Open Gmail"
        case .open(.appSettings): "Open Settings"
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
            Label("Prepare speech first", systemImage: "arrow.down.circle")
                .font(.headline)
            Text("Hermes uses the same private on-device \(model.title) model as Dictation.")
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
