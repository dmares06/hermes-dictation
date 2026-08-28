import Foundation

/// The seam between the two halves of a conversation: OpenAI Realtime is the
/// ears and the mouth, Hermes Agent is the brain.
///
/// Realtime hears the person, calls its one tool — `ask_hermes` — with their
/// words, and speaks whatever comes back. This turns Hermes's finished reply
/// into that tool result: markdown flattened for speech, any
/// `<hermes-action>` block cut out and handed to the phone's confirmation
/// card, and a note telling the voice what the screen is now showing so it
/// never claims something happened.
public enum HermesVoiceRelay {
    public struct Result: Equatable, Sendable {
        /// What the voice model receives as the tool output.
        public let output: String
        /// The phone-side action Hermes proposed, if any; still needs approval.
        public let action: VoiceAgentAction?
    }

    /// The tool the Realtime session is given. Kept in one place so the app
    /// and the backend's session config cannot drift apart.
    public static let toolName = "ask_hermes"
    public static let requestArgument = "request"

    /// Appended whenever a reply proposed an action, so the voice asks for
    /// confirmation instead of announcing a result the phone has not produced.
    public static let approvalNote =
        "The phone is now showing this for approval. Ask the user to say confirm or cancel, and do not claim it has been sent, saved, or opened."

    static let emptyReply = "Hermes did not say anything. Tell the user briefly and offer to try again."
    static let actionOnlyReply = "Hermes prepared something for the user to approve."

    public static func toolOutput(fromReply reply: String) -> Result {
        let parsed = HermesActionBlock.extract(from: reply)
        let spoken = SpokenText.plain(parsed.spoken)
        guard let action = parsed.action else {
            return Result(output: spoken.isEmpty ? emptyReply : spoken, action: nil)
        }
        let lead = spoken.isEmpty ? actionOnlyReply : spoken
        return Result(output: "\(lead) \(approvalNote)", action: action)
    }

    public static func failureOutput(_ message: String) -> String {
        "Hermes could not answer: \(message). Tell the user in one short sentence."
    }

    /// The person's words as Realtime passed them along, or nil when the call
    /// carried nothing worth sending to Hermes.
    public static func request(from arguments: [String: Any]) -> String? {
        guard let raw = arguments[requestArgument] as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
