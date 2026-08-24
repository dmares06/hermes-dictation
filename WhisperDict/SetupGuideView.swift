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
                GuideRow(number: 1, title: "Tap Record", detail: "In any text field, switch to the WhisperDict keyboard and tap Record. iOS briefly opens WhisperDict so the app—not the keyboard—can access the microphone.")
                GuideRow(number: 2, title: "Swipe back and speak", detail: "Swipe back to the app where you were typing. WhisperDict continues recording in the background.")
                GuideRow(number: 3, title: "Stop and insert", detail: "Tap Stop on the keyboard. WhisperDict transcribes on this iPhone and inserts the result into the active text field.")
                GuideRow(number: 4, title: "Optional Action Button", detail: "For a faster start, assign WhisperDict’s Start Dictation shortcut to the Action Button. Press it again, tap Stop on the keyboard, or use the Live Activity to finish.")
            }
            Section("Enable the fallback keyboard") {
                GuideRow(number: 1, title: "Open Settings", detail: "Go to Settings → General → Keyboard → Keyboards.")
                GuideRow(number: 2, title: "Add WhisperDict", detail: "Tap Add New Keyboard and choose WhisperDict.")
                GuideRow(number: 3, title: "Allow Full Access", detail: "Full Access lets the keyboard read the latest transcript from WhisperDict’s private shared container. Audio is never recorded by the keyboard.")
                GuideRow(number: 4, title: "Switch keyboards", detail: "Touch and hold the globe key in any supported text field and choose WhisperDict.")
            }
            Section("Important iOS limitation") {
                Text("Apple does not permit third-party keyboards to use the microphone. Tapping Record therefore opens WhisperDict to begin recording, just like other iPhone dictation keyboards. The Action Button, Siri, or Shortcuts can start the Apple-approved background intent without that handoff. Secure fields and apps that block custom keyboards always use Apple’s keyboard.")
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
