import AVFoundation
import SwiftUI
import UIKit

struct OnboardingView: View {
    @Environment(SharedState.self) private var settings
    let downloadService: ModelDownloadService

    @State private var page = 0
    @State private var microphonePermission = AVAudioApplication.shared.recordPermission

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                TabView(selection: $page) {
                    welcomePage.tag(0)
                    privacyPage.tag(1)
                    modelPage.tag(2)
                    keyboardPage.tag(3)
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
                .animation(.easeInOut, value: page)

                HStack(spacing: 12) {
                    if page > 0 {
                        Button("Back") { page -= 1 }
                            .buttonStyle(.bordered)
                    }
                    Button(page == 3 ? "Finish setup" : "Continue") {
                        if page == 3 {
                            settings.welcomeDone = true
                        } else {
                            page += 1
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
                    .disabled(page == 2 && !downloadService.isPrepared)
                }
                .padding(.horizontal)
                .padding(.bottom)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .interactiveDismissDisabled()
            .onAppear {
                downloadService.refresh(for: settings.modelSize)
                microphonePermission = AVAudioApplication.shared.recordPermission
            }
            .onChange(of: settings.modelSize) { _, model in
                downloadService.refresh(for: model)
            }
        }
    }

    private var welcomePage: some View {
        OnboardingPage(
            icon: "waveform.badge.mic",
            title: "Dictate privately",
            message: "WhisperDict turns your voice into polished text on this iPhone. Your recordings are not uploaded for transcription."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                OnboardingFeature(icon: "lock.shield.fill", text: "On-device speech recognition")
                OnboardingFeature(icon: "text.cursor", text: "Insert new dictation in other apps")
                OnboardingFeature(icon: "wand.and.stars", text: "Remove fillers and clean punctuation")
            }
        }
    }

    private var privacyPage: some View {
        OnboardingPage(
            icon: "mic.circle.fill",
            title: "Allow microphone access",
            message: "The main WhisperDict app records your voice. Apple does not allow third-party keyboards to use the microphone."
        ) {
            VStack(spacing: 12) {
                Label(microphoneStatus, systemImage: microphoneStatusIcon)
                    .foregroundStyle(microphonePermission == .denied ? .red : .secondary)

                if microphonePermission == .undetermined {
                    Button("Allow microphone", action: requestMicrophonePermission)
                        .buttonStyle(.borderedProminent)
                } else if microphonePermission == .denied {
                    Button("Open WhisperDict Settings", action: openAppSettings)
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private var modelPage: some View {
        OnboardingPage(
            icon: "cpu.fill",
            title: "Prepare on-device speech",
            message: "Choose a model once. Small gives this personal build its best available accuracy."
        ) {
            VStack(spacing: 14) {
                Picker("Speech model", selection: Bindable(settings).modelSize) {
                    ForEach(ModelSize.allCases) { model in
                        Text(model.title).tag(model)
                    }
                }
                .pickerStyle(.segmented)

                Text(settings.modelSize.detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if downloadService.isPreparing {
                    ProgressView(value: downloadService.progress)
                    Text("Downloading… \(Int(downloadService.progress * 100))%")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else if downloadService.isPrepared {
                    Label("Ready on this iPhone", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Button("Prepare \(settings.modelSize.title) model") {
                        Task { await downloadService.prepare(model: settings.modelSize) }
                    }
                    .buttonStyle(.borderedProminent)
                }

                if let errorMessage = downloadService.errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private var keyboardPage: some View {
        OnboardingPage(
            icon: "keyboard.fill",
            title: "Use WhisperDict anywhere",
            message: "Enable the keyboard for insertion, then assign Start Dictation to your iPhone Action Button."
        ) {
            VStack(alignment: .leading, spacing: 14) {
                OnboardingFeature(icon: "1.circle.fill", text: "Settings → General → Keyboard → Keyboards → Add New Keyboard → WhisperDict")
                OnboardingFeature(icon: "2.circle.fill", text: "Allow Full Access so the keyboard can read your private App Group transcript")
                OnboardingFeature(icon: "3.circle.fill", text: "Settings → Action Button → Shortcut → Start Dictation")
                OnboardingFeature(icon: "4.circle.fill", text: "Press and hold the physical side Action Button, speak without leaving your current app, then tap Stop on the keyboard")

                Button("Open WhisperDict Settings", action: openAppSettings)
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var microphoneStatus: String {
        switch microphonePermission {
        case .granted: "Microphone access is ready"
        case .denied: "Microphone access is turned off"
        case .undetermined: "Permission has not been requested"
        @unknown default: "Microphone permission is unavailable"
        }
    }

    private var microphoneStatusIcon: String {
        microphonePermission == .granted ? "checkmark.circle.fill" : "exclamationmark.circle"
    }

    private func requestMicrophonePermission() {
        AVAudioApplication.requestRecordPermission { granted in
            Task { @MainActor in
                microphonePermission = granted ? .granted : .denied
            }
        }
    }

    private func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

private struct OnboardingPage<Content: View>: View {
    let icon: String
    let title: String
    let message: String
    let content: Content

    init(
        icon: String,
        title: String,
        message: String,
        @ViewBuilder content: () -> Content
    ) {
        self.icon = icon
        self.title = title
        self.message = message
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                Image(systemName: icon)
                    .font(.system(size: 58, weight: .semibold))
                    .foregroundStyle(.mint)
                    .padding(.top, 36)
                Text(title)
                    .font(.largeTitle.bold())
                    .multilineTextAlignment(.center)
                Text(message)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                content
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(.background, in: RoundedRectangle(cornerRadius: 20))
            }
            .padding()
        }
    }
}

private struct OnboardingFeature: View {
    let icon: String
    let text: String

    var body: some View {
        Label {
            Text(text)
                .frame(maxWidth: .infinity, alignment: .leading)
        } icon: {
            Image(systemName: icon)
                .foregroundStyle(.mint)
        }
    }
}
