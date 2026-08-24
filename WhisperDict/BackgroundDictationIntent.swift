import AppIntents
import Foundation

@available(iOS 18.0, *)
struct StartWhisperDictIntent: AppIntent {
    static let title: LocalizedStringResource = "Start WhisperDict"
    static let description = IntentDescription("Opens WhisperDict and starts private on-device dictation.")

    func perform() async throws -> some IntentResult & OpensIntent & ProvidesDialog {
        return .result(
            opensIntent: OpenURLIntent(DictationLaunchRoute.recordingURL),
            dialog: "Opening WhisperDict"
        )
    }
}
