import Foundation

/// OpenAI Realtime allows one response at a time. Asking for another while
/// one is in flight is rejected with `conversation_already_has_active_response`
/// — which happens whenever the user speaks while Hermes is still thinking:
/// the voice starts answering them, then our function result arrives and
/// asks for its own response. Treating that as fatal ended the call every
/// time. The gate serialises those requests: send now when the line is free,
/// otherwise remember to send when the active response is done.
public struct RealtimeResponseGate: Equatable {
    /// What to do about an `error` event from the server.
    public enum ErrorVerdict: Equatable {
        /// The line was busy; the response goes out when it frees up.
        case deferred
        /// Our own request was bad; the session itself is fine.
        case ignored
        /// The session is gone; the call has to end.
        case fatal
    }

    public private(set) var responseActive = false
    public private(set) var responsePending = false

    public init() {}

    /// Whether `response.create` should be sent right now. Sending marks the
    /// line busy at once — the server's own `response.created` may land after
    /// a second request has already been made.
    public mutating func requestResponse() -> Bool {
        if responseActive {
            responsePending = true
            return false
        }
        responseActive = true
        return true
    }

    /// For lines that are only worth saying while the voice is quiet — a
    /// progress note during a long tool call. Sends when free; otherwise the
    /// line is dropped rather than queued, since it would be stale by then.
    public mutating func requestResponseIfIdle() -> Bool {
        guard !responseActive else { return false }
        responseActive = true
        return true
    }

    public mutating func noteResponseCreated() {
        responseActive = true
    }

    /// Returns true when a deferred `response.create` should be sent now.
    public mutating func noteResponseDone() -> Bool {
        responseActive = false
        defer { responsePending = false }
        return responsePending
    }

    public mutating func noteError(code: String?, type: String?) -> ErrorVerdict {
        if code == "conversation_already_has_active_response" {
            responseActive = true
            responsePending = true
            return .deferred
        }
        if Self.fatalCodes.contains(code ?? "") || type != "invalid_request_error" {
            return .fatal
        }
        // A rejected request produces no response, so the line is free again.
        responseActive = false
        return .ignored
    }

    public mutating func reset() {
        responseActive = false
        responsePending = false
    }

    private static let fatalCodes: Set<String> = ["session_expired", "session_not_found"]
}
