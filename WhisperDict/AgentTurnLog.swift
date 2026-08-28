import Foundation

/// A short trail of what the agent did on its last few turns, kept in the app
/// group so it can be read back off the phone.
///
/// A voice turn crosses five boundaries — recorder, turn detector, Whisper,
/// the Hermes gateway, and speech synthesis — and when it fails the screen
/// shows nothing but silence. `./ios_run.sh --agent-log` prints this trail so
/// the failing step is named instead of guessed at.
enum AgentTurnLog {
    static let key = "agentTurnTrail"
    /// Enough for a handful of turns; older entries fall off the front.
    static let limit = 150

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    static func note(_ event: String) {
        let defaults = UserDefaults(suiteName: SharedState.appGroupID)
        var trail = defaults?.stringArray(forKey: key) ?? []
        trail.append("\(clock.string(from: Date())) \(event)")
        if trail.count > limit { trail.removeFirst(trail.count - limit) }
        defaults?.set(trail, forKey: key)
        NSLog("WhisperDict agent: %@", event)
    }
}
