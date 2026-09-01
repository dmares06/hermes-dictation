import Foundation

/// How long a spoken conversation may sit doing nothing before it ends.
///
/// A conversation now outlives the app going to the background, which is
/// what lets it keep talking through a locked screen — but it also means
/// nothing ends one that is simply walked away from. Left alone it would
/// hold the microphone open, the orange indicator lit, and on a live call
/// the meter running. So quiet is given a limit.
///
/// Activity is anything the conversation does: a phase moving, a word
/// heard, a reply spoken. Only genuine silence on both sides counts.
public struct ConversationIdleWatch: Equatable, Sendable {
    public static let defaultTimeout: TimeInterval = 120

    private let timeout: TimeInterval
    private var lastActivityAt: TimeInterval

    public init(timeout: TimeInterval = defaultTimeout, startedAt: TimeInterval) {
        self.timeout = max(1, timeout)
        self.lastActivityAt = startedAt
    }

    public mutating func noteActivity(at time: TimeInterval) {
        lastActivityAt = time
    }

    /// Whether the conversation has been quiet for the whole timeout.
    ///
    /// A `now` earlier than the last activity is a clock that moved
    /// backwards, not two minutes of silence, and must never end a
    /// conversation that is still going.
    public func hasTimedOut(at now: TimeInterval) -> Bool {
        now - lastActivityAt >= timeout
    }
}
