import Foundation

/// How long the app stays resident in the background after its last activity,
/// ready to start a dictation without being brought to the foreground.
///
/// Mirrors the "session" model users know from other dictation keyboards: the
/// first launch is always in the foreground, every dictation inside the window
/// is not.
public enum ListeningWindowDuration: String, CaseIterable, Identifiable, Sendable {
    case off
    case fiveMinutes
    case fifteenMinutes
    case oneHour
    case always

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .off: "Off"
        case .fiveMinutes: "5 minutes"
        case .fifteenMinutes: "15 minutes"
        case .oneHour: "1 hour"
        case .always: "Until I close the app"
        }
    }

    /// Idle time before the window ends. `nil` means it never expires on its
    /// own; `0` means the window is disabled.
    public var idleInterval: TimeInterval? {
        switch self {
        case .off: 0
        case .fiveMinutes: 5 * 60
        case .fifteenMinutes: 15 * 60
        case .oneHour: 60 * 60
        case .always: nil
        }
    }

    public var isEnabled: Bool { self != .off }
}

public enum ListeningWindowPolicy {
    /// When an idle window should end, given its last activity.
    public static func expiry(
        lastActivity: Date,
        duration: ListeningWindowDuration
    ) -> Date? {
        guard let interval = duration.idleInterval else { return nil }
        return lastActivity.addingTimeInterval(interval)
    }

    public static func shouldExpire(
        now: Date,
        lastActivity: Date,
        duration: ListeningWindowDuration
    ) -> Bool {
        guard let expiry = expiry(lastActivity: lastActivity, duration: duration) else { return false }
        return now >= expiry
    }
}

/// App-group state shared between the resident app, the keyboard, the Live
/// Activity, and the App Intent. The app owns the heartbeat; everyone else
/// reads it to decide whether a start *signal* will be heard, or whether the
/// app has to be launched instead.
public enum ListeningWindowState {
    public enum Keys {
        public static let heartbeat = "listeningWindowHeartbeat"
        public static let startRequest = "listeningWindowStartRequest"
    }

    /// The resident app refreshes its heartbeat more often than this, so a
    /// heartbeat older than it means the process was suspended or killed.
    public static let staleInterval: TimeInterval = 8

    public static func markAlive(
        defaults: UserDefaults? = BackgroundDictationState.sharedDefaults,
        now: Date = Date()
    ) {
        defaults?.set(now.timeIntervalSince1970, forKey: Keys.heartbeat)
    }

    public static func end(defaults: UserDefaults? = BackgroundDictationState.sharedDefaults) {
        defaults?.removeObject(forKey: Keys.heartbeat)
        defaults?.removeObject(forKey: Keys.startRequest)
    }

    public static func isAlive(
        defaults: UserDefaults? = BackgroundDictationState.sharedDefaults,
        now: Date = Date()
    ) -> Bool {
        let heartbeat = defaults?.double(forKey: Keys.heartbeat) ?? 0
        guard heartbeat > 0 else { return false }
        return now.timeIntervalSince1970 - heartbeat <= staleInterval
    }

    /// Asks the resident app to start recording. Safe to call from any
    /// process in the app group; a fresh id guarantees each request is seen
    /// once even when two arrive before the app polls.
    public static func requestStart(defaults: UserDefaults? = BackgroundDictationState.sharedDefaults) {
        defaults?.set(UUID().uuidString, forKey: Keys.startRequest)
    }

    public static func consumeStartRequest(
        defaults: UserDefaults? = BackgroundDictationState.sharedDefaults
    ) -> Bool {
        guard defaults?.string(forKey: Keys.startRequest) != nil else { return false }
        defaults?.removeObject(forKey: Keys.startRequest)
        return true
    }
}
