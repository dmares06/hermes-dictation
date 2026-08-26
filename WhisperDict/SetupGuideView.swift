import AVFoundation
import Speech
import SwiftUI

struct SetupGuideView: View {
    @State private var permissionStatus: String?

    var body: some View {
        List {
            Section("Dictate from the keyboard (hands-free)") {
                GuideRow(number: 1, title: "Add the keyboard", detail: "Settings → General → Keyboard → Keyboards → Add New Keyboard → WhisperDict.")
                GuideRow(number: 2, title: "Allow Full Access", detail: "Tap the WhisperDict keyboard in the same list and turn on Allow Full Access. iOS only lets a keyboard use the microphone with Full Access enabled.")
                GuideRow(number: 3, title: "Grant permissions here", detail: "Use the button below so microphone and speech recognition are already approved when you dictate from the keyboard.")
                GuideRow(number: 4, title: "Dictate anywhere", detail: "In any app, switch to the WhisperDict keyboard and tap Dictate. Speak, tap Stop, and the cleaned-up text stays in the field.")
                Button {
                    requestKeyboardPermissions()
                } label: {
                    Label(permissionStatus ?? "Grant microphone & speech access", systemImage: "checkmark.shield")
                }
            }
            Section("Dictate accurately") {
                GuideRow(number: 1, title: "Prepare the model", detail: "Download the on-device speech model from the WhisperDict home screen.")
                GuideRow(number: 2, title: "Record in WhisperDict", detail: "Tap the microphone, speak naturally, and tap Stop. Calls, route changes, and backgrounding safely end the recording.")
                GuideRow(number: 3, title: "Copy or insert", detail: "Copy the result, or use the WhisperDict keyboard’s Insert Latest button in another app.")
            }
            Section("Start while typing") {
                GuideRow(number: 1, title: "Assign the Action Button", detail: "In Settings → Action Button → Shortcut, choose WhisperDict’s Start Dictation shortcut.")
                GuideRow(number: 2, title: "Press and speak", detail: "Press the Action Button while typing. WhisperDict opens so the app—not the keyboard—can access the microphone.")
                GuideRow(number: 3, title: "Stop recording", detail: "Press the Action Button again, tap Stop after returning to the keyboard, or use the Live Activity Stop control.")
                GuideRow(number: 4, title: "Insert the result", detail: "Return to the text field, choose the WhisperDict keyboard, and tap Insert Latest. Review the text before sending.")
            }
            Section("Enable the fallback keyboard") {
                GuideRow(number: 1, title: "Open Settings", detail: "Go to Settings → General → Keyboard → Keyboards.")
                GuideRow(number: 2, title: "Add WhisperDict", detail: "Tap Add New Keyboard and choose WhisperDict.")
                GuideRow(number: 3, title: "Allow Full Access", detail: "Full Access lets the keyboard read the latest transcript from WhisperDict’s private shared container. Audio is never recorded by the keyboard.")
                GuideRow(number: 4, title: "Switch keyboards", detail: "Touch and hold the globe key in any supported text field and choose WhisperDict.")
            }
            Section("Important iOS limitations") {
                Text("The keyboard microphone needs Allow Full Access; without it, use the Action Button flow instead. Keyboard dictation uses Apple’s on-device speech recognizer because keyboard extensions cannot fit the Whisper model in memory — the Action Button flow still transcribes with Whisper for maximum accuracy. Secure fields and apps that block custom keyboards always use Apple’s keyboard, and the keyboard cannot launch WhisperDict through its private URL scheme.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Setup guide")
    }

    private func requestKeyboardPermissions() {
        SFSpeechRecognizer.requestAuthorization { speechStatus in
            AVAudioApplication.requestRecordPermission { micGranted in
                DispatchQueue.main.async {
                    if micGranted && speechStatus == .authorized {
                        permissionStatus = "Microphone & speech access granted"
                    } else if !micGranted {
                        permissionStatus = "Microphone denied — enable it in Settings → WhisperDict"
                    } else {
                        permissionStatus = "Speech recognition denied — enable it in Settings → WhisperDict"
                    }
                }
            }
        }
    }
}

private struct GuideRow: View {
    let number: Int
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Text("\(number)")
                .font(.headline)
                .frame(width: 28, height: 28)
                .background(.tint, in: Circle())
                .foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}
