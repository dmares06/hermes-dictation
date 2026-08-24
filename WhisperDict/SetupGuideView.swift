import SwiftUI

struct SetupGuideView: View {
    var body: some View {
        List {
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
            Section("Important iOS limitation") {
                Text("Apple does not permit third-party keyboards to use the microphone or launch WhisperDict through its private URL scheme. Start recording with the Action Button, Siri, or the Start Dictation shortcut; the keyboard only stops an active recording and inserts the finished transcript. Secure fields and apps that block custom keyboards always use Apple’s keyboard.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Setup guide")
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
