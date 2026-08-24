import AppIntents
import SwiftUI

@available(iOS 18.0, *)
struct WhisperDictShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
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

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(state)
        }
    }
}
