import Foundation

/// The bridge from a Hermes Agent reply back to the phone.
///
/// Hermes runs on a Mac and cannot open Messages, add a Reminder, or launch
/// an app on the iPhone. When the user asks for one of those, it is told to
/// put a small JSON block in its reply:
///
///     <hermes-action>{"type": "message", "body": "Running late, sorry!"}</hermes-action>
///
/// The block is cut out of what gets spoken and turned into the same
/// `VoiceAgentAction` the Realtime path produces — through the same
/// validators — so it lands on the same confirmation card. The model
/// proposes; the person still approves.
public enum HermesActionBlock {
    public struct Parsed: Equatable, Sendable {
        public let spoken: String
        public let action: VoiceAgentAction?
    }

    public static let openTag = "<hermes-action>"
    public static let closeTag = "</hermes-action>"

    public static func extract(from reply: String) -> Parsed {
        var text = reply
        var action: VoiceAgentAction?
        var isFirst = true
        while let open = text.range(of: openTag),
              let close = text.range(of: closeTag, range: open.upperBound..<text.endIndex) {
            if isFirst {
                action = self.action(fromJSON: String(text[open.upperBound..<close.lowerBound]))
                isFirst = false
            }
            text.removeSubrange(open.lowerBound..<close.upperBound)
        }
        return Parsed(spoken: SpokenText.collapseWhitespace(text), action: action)
    }

    private static func action(fromJSON json: String) -> VoiceAgentAction? {
        guard let data = json.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = object["type"] as? String
        else { return nil }

        switch type {
        case "message":
            guard let body = object["body"] as? String else { return nil }
            return VoiceAgentAction.validatedMessage(body)
        case "email":
            guard let recipient = object["recipient"] as? String,
                  let subject = object["subject"] as? String,
                  let body = object["body"] as? String
            else { return nil }
            return object["send"] as? Bool == true
                ? VoiceAgentAction.validatedSentEmail(recipient: recipient, subject: subject, body: body)
                : VoiceAgentAction.validatedEmail(recipient: recipient, subject: subject, body: body)
        case "note":
            guard let body = object["body"] as? String else { return nil }
            return object["apple"] as? Bool == true
                ? VoiceAgentAction.validatedNote(body)
                : VoiceAgentAction.validatedSavedNote(body)
        case "reminder":
            guard let title = object["title"] as? String else { return nil }
            let due = (object["due"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
            return VoiceAgentAction.validatedReminder(title: title, dueDate: due)
        case "open":
            guard let destination = object["destination"] as? String else { return nil }
            return VoiceAgentAction.validatedDestination(destination)
        case "shortcut":
            guard let name = object["name"] as? String else { return nil }
            return VoiceAgentAction.validatedShortcut(name)
        default:
            return nil
        }
    }
}
