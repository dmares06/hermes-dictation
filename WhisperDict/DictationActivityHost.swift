import ActivityKit
import Foundation

/// The one owner of the dictation Live Activity.
///
/// iOS only lets an app *start* a Live Activity from the foreground, so the
/// listening window starts it while the app is visible and every later phase
/// — recording, transcribing, ready — is an update. Outside a window the
/// activity behaves as before: it appears for a recording and ends with it.
@MainActor
final class DictationActivityHost {
    private var activity: Activity<WhisperDictActivityAttributes>?
    private(set) var startedAt: Date?

    /// While true, finishing a dictation updates the activity instead of
    /// ending it, so the next dictation can be started from it.
    var keepsActivityAlive = false

    var isActive: Bool { activity != nil }

    /// Stored properties all have defaults, so construction needs no actor —
    /// which lets it serve as a default argument.
    nonisolated init() {}

    func ensureStarted(_ state: BackgroundDictationActivityContentState) async {
        if activity != nil {
            await update(state)
            return
        }
        // A previous process may have left an activity behind; take it over
        // rather than stacking a second one in the Dynamic Island.
        if let orphan = Activity<WhisperDictActivityAttributes>.activities.first {
            activity = orphan
            startedAt = state.startedAt
            await update(state)
            return
        }
        do {
            let content = ActivityContent(state: contentState(state), staleDate: staleDate(for: state))
            if #available(iOS 18.0, *) {
                activity = try Activity.request(
                    attributes: WhisperDictActivityAttributes(),
                    content: content,
                    pushType: nil,
                    style: .standard
                )
            } else {
                activity = try Activity.request(
                    attributes: WhisperDictActivityAttributes(),
                    content: content,
                    pushType: nil
                )
            }
            startedAt = state.startedAt
        } catch {
            // Expected when the app is backgrounded; the recording itself
            // does not depend on the indicator.
            NSLog("WhisperDict Live Activity could not start: \(error.localizedDescription)")
        }
    }

    func update(_ state: BackgroundDictationActivityContentState) async {
        guard let activity else { return }
        if state.phase == .recording { startedAt = state.startedAt }
        await activity.update(ActivityContent(state: contentState(state), staleDate: staleDate(for: state)))
    }

    /// Finishes a dictation: leaves the activity up in the window's idle look
    /// when it is being kept alive, ends it otherwise.
    func finish(
        _ finalState: BackgroundDictationActivityContentState?,
        dismissalPolicy: ActivityUIDismissalPolicy
    ) async {
        if keepsActivityAlive, let finalState {
            await update(finalState)
            return
        }
        await end(finalState, dismissalPolicy: dismissalPolicy)
    }

    func end(
        _ finalState: BackgroundDictationActivityContentState?,
        dismissalPolicy: ActivityUIDismissalPolicy
    ) async {
        guard let activity else { return }
        let content = finalState.map {
            ActivityContent(state: contentState($0), staleDate: nil)
        }
        await activity.end(content, dismissalPolicy: dismissalPolicy)
        self.activity = nil
        startedAt = nil
    }

    private func contentState(
        _ state: BackgroundDictationActivityContentState
    ) -> WhisperDictActivityAttributes.ContentState {
        .init(phase: state.phase, startedAt: state.startedAt)
    }

    private func staleDate(for state: BackgroundDictationActivityContentState) -> Date? {
        switch state.phase {
        case .recording: state.startedAt.addingTimeInterval(BackgroundDictationState.maximumRecordingDuration)
        case .transcribing: Date().addingTimeInterval(60)
        case .idle, .ready, .failed: nil
        }
    }
}
