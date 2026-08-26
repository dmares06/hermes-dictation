import AppIntents
import Foundation

/// Always brings WhisperDict forward and starts (or stops) a dictation there.
@available(iOS 18.0, *)
struct StartWhisperDictIntent: AppIntent {
    static let title: LocalizedStringResource = "Start WhisperDict"
    static let description = IntentDescription("Opens WhisperDict and starts private on-device dictation.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult & ProvidesDialog {
        BackgroundDictationState.requestForegroundToggle()
        return .result(dialog: "Opening WhisperDict")
    }
}

/// Starts a dictation without leaving the current app whenever WhisperDict
/// is resident in the background.
///
/// `openAppWhenRun` has to be a compile-time constant, so this intent never
/// opens the app on its own. When no listening window is alive it asks the
/// system to continue in the foreground instead — one tap, only in the cold
/// case — and the foreground toggle takes over from there.
@available(iOS 18.0, *)
struct TalkToWhisperDictIntent: ForegroundContinuableIntent {
    static let title: LocalizedStringResource = "Talk to WhisperDict"
    static let description = IntentDescription("Dictates in the background while WhisperDict is listening; otherwise opens it.")
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult {
        guard ListeningWindowState.isAlive() else {
            // Set before the hop so the flag is there whichever fires first:
            // the scene becoming active or the continuation closure.
            BackgroundDictationState.requestForegroundToggle()
            throw needsToContinueInForegroundError(
                IntentDialog("Open WhisperDict to start listening?")
            ) {
                BackgroundDictationState.requestForegroundToggle()
            }
        }
        switch BackgroundDictationState.phase() {
        case .recording:
            BackgroundDictationState.requestStop()
            DictationSignalCenter.post(.stop)
        case .transcribing:
            break
        case .idle, .ready, .failed:
            ListeningWindowState.requestStart()
            DictationSignalCenter.post(.start)
        }
        return .result()
    }
}
