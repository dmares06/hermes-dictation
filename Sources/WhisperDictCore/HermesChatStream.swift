import Foundation

/// What a streaming turn against a Hermes Agent gateway tells the client,
/// reduced to the handful of things a voice UI acts on.
public enum HermesStreamEvent: Equatable, Sendable {
    case created(responseID: String)
    case textDelta(String)
    /// Hermes started running a tool server-side. Shown as "Hermes is
    /// searching…" so the silence has a reason.
    case toolStarted(name: String, callID: String)
    case toolFinished(callID: String)
    /// Terminal event. `text` is the assistant's whole reply as assembled
    /// from the stream.
    case completed(responseID: String, text: String)
    case failed(message: String)
}

/// Turns the Server-Sent Events of `POST /v1/chat/completions` on a Hermes
/// gateway into `HermesStreamEvent`s.
///
/// The phone uses this endpoint rather than `/v1/responses` because its
/// `X-Hermes-Session-Id` continuity keeps the transcript on the gateway's
/// own session store: the Responses-style `conversation` chaining was found
/// to re-append the whole history on every turn (904 messages after a few
/// minutes of talking), which is what made each turn slower than the last.
///
/// Feed it one line at a time as they arrive; a frame ends at a blank line.
/// Ordinary chunks carry the reply in `choices[0].delta.content`; the
/// gateway's `event: hermes.tool.progress` frames announce tools. Anything
/// unrecognised is dropped rather than thrown, because a stream that dies
/// on one odd frame loses the reply.
public struct HermesChatStreamParser: Sendable {
    private var eventName: String?
    private var dataLines: [String] = []
    private var responseID = ""
    private var text = ""

    public init() {}

    public mutating func feed(line: String) -> HermesStreamEvent? {
        if line.isEmpty { return flushFrame() }
        if line.hasPrefix(":") { return nil }
        if line.hasPrefix("event:") {
            eventName = Self.value(after: "event:", in: line)
            return nil
        }
        guard line.hasPrefix("data:") else { return nil }
        dataLines.append(Self.value(after: "data:", in: line))
        return nil
    }

    /// Call when the connection closes, in case the last frame had no
    /// trailing blank line.
    public mutating func finish() -> HermesStreamEvent? {
        flushFrame()
    }

    private static func value(after prefix: String, in line: String) -> String {
        var payload = line.dropFirst(prefix.count)
        if payload.hasPrefix(" ") { payload = payload.dropFirst() }
        return String(payload)
    }

    private mutating func flushFrame() -> HermesStreamEvent? {
        defer { eventName = nil; dataLines = [] }
        guard !dataLines.isEmpty else { return nil }
        let payload = dataLines.joined(separator: "\n")
        guard payload != "[DONE]",
              let data = payload.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        if eventName == "hermes.tool.progress" { return Self.toolEvent(from: object) }
        return chunkEvent(from: object)
    }

    private static func toolEvent(from object: [String: Any]) -> HermesStreamEvent? {
        guard let callID = object["toolCallId"] as? String else { return nil }
        switch object["status"] as? String {
        case "running": return .toolStarted(name: object["tool"] as? String ?? "tool", callID: callID)
        case "completed": return .toolFinished(callID: callID)
        default: return nil
        }
    }

    private mutating func chunkEvent(from object: [String: Any]) -> HermesStreamEvent? {
        if let error = object["error"] as? [String: Any], object["choices"] == nil {
            return .failed(message: Self.message(in: error))
        }
        guard object["object"] as? String == "chat.completion.chunk",
              let choice = (object["choices"] as? [[String: Any]])?.first
        else { return nil }
        if let id = object["id"] as? String, responseID.isEmpty { responseID = id }
        let delta = choice["delta"] as? [String: Any] ?? [:]

        if let finish = choice["finish_reason"] as? String {
            guard finish == "stop" else {
                let error = object["error"] as? [String: Any]
                return .failed(message: error.map(Self.message(in:)) ?? "Hermes could not finish the reply (\(finish)).")
            }
            if let content = delta["content"] as? String { text += content }
            return .completed(responseID: responseID, text: text)
        }
        if let content = delta["content"] as? String, !content.isEmpty {
            text += content
            return .textDelta(content)
        }
        if delta["role"] as? String == "assistant" {
            return .created(responseID: responseID)
        }
        return nil
    }

    private static func message(in error: [String: Any]) -> String {
        error["message"] as? String ?? "Hermes could not finish the reply."
    }
}
