import Foundation

/// Turns the stored default recipient into the list `MFMessageComposeViewController`
/// expects.
///
/// Pre-addressing the sheet is what removes the trip back to Messages, so a
/// value that is only whitespace has to read as "no recipient" rather than as
/// a blank address the compose sheet would reject.
public enum MessageRecipients {
    public static func normalize(_ stored: String?) -> [String] {
        guard let trimmed = stored?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return [] }
        return [trimmed]
    }
}
