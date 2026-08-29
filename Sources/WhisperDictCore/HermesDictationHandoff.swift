import Foundation

/// A dictation sent from the dictation screen to Hermes. The text goes to
/// Hermes framed as what it is, and the app labels both ends — the
/// dictation and the conversation — so it is clear this went to Hermes.
public enum HermesDictationHandoff {
    public static let milestone = "Dictation sent to Hermes"
    public static let badge = "Sent to Hermes"

    public static func request(for dictation: String) -> String {
        let text = dictation.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        I dictated this on my phone and I'm sending it to you: \
        act on it if it asks for something; if it's just a note, ask me what I want done with it.

        \(text)
        """
    }
}
