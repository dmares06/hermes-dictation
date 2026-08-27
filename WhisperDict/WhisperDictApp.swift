import AppIntents
import SwiftUI

@available(iOS 18.0, *)
struct WhisperDictShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: TalkToWhisperDictIntent(),
            phrases: [
                "Talk to \(.applicationName)",
                "Dictate with \(.applicationName)",
            ],
            shortTitle: "Talk",
            systemImageName: "waveform"
        )
        AppShortcut(
            intent: StartWhisperDictIntent(),
            phrases: [
                "Start dictating with \(.applicationName)",
                "Record with \(.applicationName)",
            ],
            shortTitle: "Start Dictation",
            systemImageName: "mic.fill"
        )
    }
}

@main
struct WhisperDictApp: App {
    @State private var state = SharedState()

    init() {
        BackgroundDictationState.recoverInterruptedSession()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(state)
        }
    }
}
