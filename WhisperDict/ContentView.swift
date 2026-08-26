import AVFoundation
import MessageUI
import SwiftUI

struct MessageComposePayload: Identifiable {
    let id = UUID()
    let body: String
    /// Pre-addresses the compose sheet so dictating into Messages does not
    /// mean returning to the app and retyping a name. Empty is valid: the
    /// sheet then opens with the text and an empty To field.
    var recipients: [String] = []
}

struct ContentView: View {
    private enum RootTab: Hashable {
        case dictation
        case notes
        case agent
    }

    @Environment(SharedState.self) private var settings
    @Environment(\.scenePhase) private var scenePhase
    @State private var downloadService = ModelDownloadService()
    @State private var activityHost: DictationActivityHost
    @State private var dictation: DictationSessionController
    @State private var listening: ListeningWindowController
    @State private var notes = NotesController()
    @State private var agent = VoiceAgentController()
    @State private var reminderPrefill: String?
    @State private var copiedText = ""
    @State private var selectedTab: RootTab = .dictation
    @State private var messagePayload: MessageComposePayload?
    @AppStorage(
        BackgroundDictationState.Keys.foregroundToggleRequest,
        store: BackgroundDictationState.sharedDefaults
    ) private var foregroundToggleRequest = ""

    init() {
        // One activity host: the window starts the Live Activity while the
        // app is visible and dictation updates it from the background.
        let host = DictationActivityHost()
        _activityHost = State(initialValue: host)
        _dictation = State(initialValue: DictationSessionController(activityHost: host))
        _listening = State(initialValue: ListeningWindowController(activityHost: host))
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            dictationView
                .tag(RootTab.dictation)
                .tabItem { Label("Dictation", systemImage: "mic.fill") }

            NotesView(controller: notes)
                .tag(RootTab.notes)
                .tabItem { Label("Notes", systemImage: "note.text") }

            VoiceAgentView(controller: agent, downloadService: downloadService)
                .tag(RootTab.agent)
                .tabItem { Label("Agent", systemImage: "waveform.and.person.filled") }
        }
        .tint(.mint)
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                handlePendingShortcutToggle()
                refreshListeningWindow()
                return
            }
            Task {
                if !dictation.isKeyboardHandoffSession {
                    await dictation.stopIfNeeded(settings: settings)
                }
                await agent.stopIfNeeded(settings: settings)
            }
        }
        .onAppear {
            downloadService.refresh(for: settings.modelSize)
            handlePendingShortcutToggle()
            wireListeningWindow()
            refreshListeningWindow()
            agent.notes = notes
        }
        .sheet(item: $reminderPrefill) { text in
            TranscriptReminderSheet(text: text) { draft in
                Task { await notes.addReminder(draft) }
            }
        }
        .onChange(of: settings.listeningWindow) { _, _ in refreshListeningWindow() }
        .onChange(of: downloadService.isPrepared) { _, _ in refreshListeningWindow() }
        .onChange(of: listening.isListening) { _, isListening in
            dictation.usesSharedAudioSession = isListening
        }
        .onChange(of: dictation.phase) { _, phase in
            // Every finished dictation restarts the idle clock.
            if phase == .ready { listening.noteActivity() }
        }
        .onChange(of: foregroundToggleRequest) { _, request in
            guard !request.isEmpty else { return }
            handlePendingShortcutToggle()
        }
        .onChange(of: settings.modelSize) { _, model in
            downloadService.refresh(for: model)
        }
        .fullScreenCover(isPresented: onboardingPresented) {
            OnboardingView(downloadService: downloadService)
                .environment(settings)
        }
        .onOpenURL { url in
            guard url.scheme == "whisperdict" else { return }
            if url.host == "agent" {
                selectedTab = .agent
                return
            }
            if DictationLaunchRoute.isStoppingURL(url) {
                selectedTab = .dictation
                Task { await dictation.stopFromKeyboard(settings: settings) }
                return
            }
            guard DictationLaunchRoute.isRecordingURL(url) else { return }
            runShortcutToggle()
        }
        .sheet(item: $messagePayload) { payload in
            MessageComposeView(body: payload.body, recipients: payload.recipients)
        }
    }

    private func handlePendingShortcutToggle() {
        guard BackgroundDictationState.consumeForegroundToggleRequest() else { return }
        runShortcutToggle()
    }

    private func wireListeningWindow() {
        listening.isBusy = { dictation.isRecording || dictation.isBusy }
        listening.onStartRequested = {
            guard downloadService.isPrepared else {
                BackgroundDictationState.fail("Prepare the speech model in WhisperDict before recording.")
                return
            }
            await dictation.startFromKeyboard(settings: settings)
        }
    }

    /// The window only opens once the app can actually record: microphone
    /// granted and a model on disk. Anything less falls back to launching.
    private func refreshListeningWindow() {
        guard downloadService.isPrepared,
              AVAudioApplication.shared.recordPermission == .granted
        else {
            listening.deactivate()
            return
        }
        listening.activate(duration: settings.listeningWindow)
    }

    private func runShortcutToggle() {
        selectedTab = .dictation
        Task {
            if !downloadService.isPrepared {
                await downloadService.prepare(model: settings.modelSize)
            }
            guard downloadService.isPrepared else {
                BackgroundDictationState.fail(
                    downloadService.errorMessage ?? "Prepare the speech model in WhisperDict before recording."
                )
                return
            }
            await dictation.toggleFromShortcut(settings: settings)
        }
    }

    private var dictationView: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 20) {
                    RecordingCard(
                        dictation: dictation,
                        modelReady: downloadService.isPrepared,
                        recordButtonColor: settings.recordButtonColor,
                        action: { Task { await dictation.toggleRecording(settings: settings) } }
                    )

                    if !downloadService.isPrepared {
                        ModelPreparationCard(service: downloadService, model: settings.modelSize)
                    }

                    if !dictation.transcript.isEmpty {
                        TranscriptCard(
                            transcript: dictation.transcript,
                            interrupted: dictation.wasInterrupted,
                            copied: copiedText == dictation.transcript,
                            copyAction: { copy(dictation.transcript) },
                            messageAction: {
                                messagePayload = MessageComposePayload(
                                    body: dictation.transcript,
                                    recipients: settings.messageRecipients
                                )
                            },
                            noteAction: {
                                if notes.saveNote(dictation.transcript) != nil { selectedTab = .notes }
                            },
                            remindAction: { reminderPrefill = dictation.transcript }
                        )
                    }

                    if !dictation.history.isEmpty {
                        HistorySection(
                            transcripts: dictation.history,
                            copyAction: copy,
                            clearAction: dictation.clearHistory
                        )
                    }

                    KeyboardTipCard()
                }
                .padding()
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("WhisperDict")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(destination: SettingsView()) {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
            }
            .alert("Microphone access needed", isPresented: $dictation.showsMicrophoneSettings) {
                Button("Open Settings", action: dictation.openAppSettings)
                Button("Not now", role: .cancel) {}
            } message: {
                Text("Turn on Microphone access for WhisperDict, then return here to record.")
            }
        }
    }

    private func copy(_ text: String) {
        dictation.copyTranscript(text)
        copiedText = text
        Task {
            try? await Task.sleep(for: .seconds(2))
            if copiedText == text { copiedText = "" }
        }
    }

    private var onboardingPresented: Binding<Bool> {
        Binding(
            get: { !settings.welcomeDone },
            set: { isPresented in
                if !isPresented { settings.welcomeDone = true }
            }
        )
    }

}

private struct RecordingCard: View {
    let dictation: DictationSessionController
    let modelReady: Bool
    let recordButtonColor: AppearanceColor
    let action: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 5) {
                Text(dictation.statusText)
                    .font(.headline)
                    .foregroundStyle(statusColor)
                    .multilineTextAlignment(.center)
                if dictation.isRecording {
                    Text(duration)
                        .font(.system(.title3, design: .monospaced, weight: .medium))
                        .contentTransition(.numericText())
                } else {
                    Text(modelReady ? "Your audio stays on this device." : "Prepare the model to begin.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            LevelMeter(level: dictation.audioLevel, active: dictation.isRecording)

            Button(action: action) {
                ZStack {
                    Circle()
                        .fill(buttonColor)
                        .frame(width: 108, height: 108)
                        .shadow(color: buttonColor.opacity(0.25), radius: 18, y: 8)
                    if dictation.isBusy {
                        ProgressView().tint(buttonForegroundColor).scaleEffect(1.4)
                    } else {
                        Image(systemName: dictation.isRecording ? "stop.fill" : "mic.fill")
                            .font(.system(size: 38, weight: .semibold))
                            .foregroundStyle(buttonForegroundColor)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(dictation.isBusy)
            .accessibilityLabel(dictation.isRecording ? "Stop recording" : "Start recording")
            .accessibilityHint("Records speech for private on-device transcription")
            .sensoryFeedback(.start, trigger: dictation.isRecording)

            Text(dictation.isRecording ? "Tap when you’re finished" : "Tap, speak naturally, then tap again")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
        .padding(.horizontal)
        .background(.background, in: RoundedRectangle(cornerRadius: 24))
    }

    private var duration: String {
        String(format: "%02d:%02d", dictation.elapsedSeconds / 60, dictation.elapsedSeconds % 60)
    }

    private var statusColor: Color {
        if case .failed = dictation.phase { return .red }
        return dictation.isRecording ? .red : .primary
    }

    private var buttonColor: Color {
        dictation.isRecording ? .red : Color(appearanceColor: recordButtonColor)
    }

    private var buttonForegroundColor: Color {
        guard !dictation.isRecording, recordButtonColor.prefersDarkForeground else { return .white }
        return .black
    }
}

private struct LevelMeter: View {
    let level: Float
    let active: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 5) {
            ForEach(0..<15, id: \.self) { index in
                Capsule()
                    .fill(barColor(index: index))
                    .frame(width: 5, height: barHeight(index: index))
            }
        }
        .frame(height: 34)
        .accessibilityHidden(true)
    }

    private func barHeight(index: Int) -> CGFloat {
        guard active else { return 5 }
        let centerDistance = abs(index - 7)
        let shape = max(0.25, 1 - Float(centerDistance) * 0.08)
        return CGFloat(5 + 29 * min(1, level * 1.8) * shape)
    }

    private func barColor(index: Int) -> Color {
        active && Float(index) / 15 < level ? .red : .secondary.opacity(0.25)
    }
}

private struct ModelPreparationCard: View {
    let service: ModelDownloadService
    let model: ModelSize

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Prepare on-device speech", systemImage: "arrow.down.circle")
                .font(.headline)
            Text("Download the \(model.title) model once. The \(model.title.lowercased()) model is \(model.detail.lowercased()).")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if service.isPreparing {
                ProgressView(value: service.progress)
                Text("Downloading… \(Int(service.progress * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Button("Prepare model") {
                    Task { await service.prepare(model: model) }
                }
                .buttonStyle(.borderedProminent)
            }
            if let errorMessage = service.errorMessage {
                Text(errorMessage).font(.footnote).foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 18))
    }
}

private struct TranscriptCard: View {
    let transcript: String
    let interrupted: Bool
    let copied: Bool
    let copyAction: () -> Void
    let messageAction: () -> Void
    let noteAction: () -> Void
    let remindAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Latest transcript", systemImage: "text.quote")
                    .font(.headline)
                Spacer()
                Button(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc", action: copyAction)
                    .font(.subheadline.weight(.semibold))
            }
            HStack(spacing: 10) {
                Button("Message", systemImage: "message.fill", action: messageAction)
                Button("Note", systemImage: "note.text.badge.plus", action: noteAction)
                Button("Remind", systemImage: "bell.badge", action: remindAction)
            }
            .font(.subheadline.weight(.semibold))
            .buttonStyle(.bordered)
            .tint(.mint)
            Text(transcript)
                .font(.body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if interrupted {
                Label("Recording ended after an interruption; review the final words.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 18))
    }
}

struct MessageComposeView: UIViewControllerRepresentable {
    let body: String
    var recipients: [String] = []

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIViewController(context: Context) -> UIViewController {
        guard MFMessageComposeViewController.canSendText() else {
            return UIActivityViewController(activityItems: [body], applicationActivities: nil)
        }
        let controller = MFMessageComposeViewController()
        controller.body = body
        if !recipients.isEmpty {
            controller.recipients = recipients
        }
        controller.messageComposeDelegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}

    final class Coordinator: NSObject, MFMessageComposeViewControllerDelegate {
        func messageComposeViewController(
            _ controller: MFMessageComposeViewController,
            didFinishWith result: MessageComposeResult
        ) {
            controller.dismiss(animated: true)
        }
    }
}

/// Turns a dictated sentence into a reminder, showing how it was understood
/// before anything is added.
private struct TranscriptReminderSheet: View {
    let text: String
    let onAdd: (ReminderDraft) -> Void
    @Environment(\.dismiss) private var dismiss

    private var draft: ReminderDraft? { ReminderParser.parse(text) }

    var body: some View {
        NavigationStack {
            Form {
                Section("From your dictation") { Text(text) }
                Section("Reminder") {
                    if let draft {
                        LabeledContent("Title", value: draft.title)
                        LabeledContent("When", value: draft.dueDate?.formatted(date: .abbreviated, time: .shortened) ?? "No time")
                    } else {
                        Text("Couldn't find something to remind you about in that sentence.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Add reminder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        if let draft { onAdd(draft) }
                        dismiss()
                    }
                    .disabled(draft == nil)
                }
            }
        }
    }
}

extension String: @retroactive Identifiable {
    public var id: String { self }
}

private struct HistorySection: View {
    let transcripts: [SavedTranscript]
    let copyAction: (String) -> Void
    let clearAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Recent dictations").font(.headline)
                Spacer()
                Button("Clear", role: .destructive, action: clearAction).font(.subheadline)
            }
            ForEach(transcripts.prefix(10)) { item in
                Button { copyAction(item.text) } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(item.text).lineLimit(3).foregroundStyle(.primary)
                        Text(item.createdAt, style: .relative).font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Copies this transcript")
                if item.id != transcripts.prefix(10).last?.id { Divider() }
            }
        }
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 18))
    }
}

private struct KeyboardTipCard: View {
    var body: some View {
        NavigationLink(destination: SetupGuideView()) {
            HStack(spacing: 12) {
                Image(systemName: "keyboard").font(.title2).foregroundStyle(.mint)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Use your transcript anywhere").font(.headline).foregroundStyle(.primary)
                    Text("Enable the keyboard to type or insert your latest dictation in supported apps.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .padding()
            .background(.background, in: RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    ContentView().environment(SharedState(defaults: .standard))
}
