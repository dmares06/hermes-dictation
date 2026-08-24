import AppIntents
import Foundation

@available(iOS 18.0, *)
struct StartWhisperDictIntent: AppIntent {
    static let title: LocalizedStringResource = "Start WhisperDict"
    static let description = IntentDescription("Opens WhisperDict and starts private on-device dictation.")
    static var openAppWhenRun: Bool { true }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        BackgroundDictationState.requestForegroundToggle()
        return .result(dialog: "Opening WhisperDict")
    }
}
