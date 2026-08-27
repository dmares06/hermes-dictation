import Foundation

public struct ReminderDraft: Equatable, Sendable {
    public static let maximumTitleLength = 200

    public let title: String
    public let dueDate: Date?

    public init(title: String, dueDate: Date? = nil) {
        self.title = title
        self.dueDate = dueDate
    }
}

/// Turns "remind me to call the dentist tomorrow at 9" into a title and a
/// due date, so a dictated sentence becomes a real system reminder.
public enum ReminderParser {
    private static let leadIns = [
        "set a reminder to", "set a reminder for", "set reminder to", "set reminder for",
        "add a reminder to", "add a reminder for", "add reminder to", "add reminder for",
        "create a reminder to", "create a reminder for",
        "remind me to", "reminder to", "reminder for", "remind me",
        // Bare forms last so the longer "… to/for" variants match first.
        "set a reminder", "add a reminder", "create a reminder", "set reminder", "add reminder", "reminder",
    ]

    /// Trailing connectives left dangling once a date phrase is removed.
    private static let danglingWords: Set<String> = ["at", "on", "by", "in", "for", "the", "and", "to", "around"]

    public static func parse(_ input: String, now: Date = Date()) -> ReminderDraft? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        let lowered = text.lowercased()
        for leadIn in leadIns where lowered.hasPrefix(leadIn) {
            text = String(text.dropFirst(leadIn.count))
            break
        }

        let dueDate = extractDate(from: &text, now: now)
        let title = tidy(text)
        guard !title.isEmpty, title.count <= ReminderDraft.maximumTitleLength else { return nil }
        return ReminderDraft(title: title, dueDate: dueDate)
    }

    /// - Note: `now` only picks between candidate matches. NSDataDetector has
    ///   no reference-date parameter, so it resolves relative phrases like
    ///   "tomorrow" against the system clock — `now` cannot move them.
    private static func extractDate(from text: inout String, now: Date) -> Date? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
        else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        let matches = detector.matches(in: text, options: [], range: range)
        // The data detector resolves relative phrases ("tomorrow at 5")
        // against the current clock. Prefer the last future match so a
        // leading "at 5" in the title does not win over "tomorrow".
        guard let match = matches.last(where: { ($0.date ?? .distantPast) > now }) ?? matches.last,
              let date = match.date,
              let swiftRange = Range(match.range, in: text)
        else { return nil }
        text.removeSubrange(swiftRange)
        return date
    }

    private static func tidy(_ raw: String) -> String {
        var words = raw
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!"))
            .split(separator: " ")
            .map(String.init)
        while let last = words.last, danglingWords.contains(last.lowercased()) {
            words.removeLast()
        }
        while let first = words.first, danglingWords.contains(first.lowercased()) {
            words.removeFirst()
        }
        guard let first = words.first else { return "" }
        words[0] = first.prefix(1).uppercased() + first.dropFirst()
        return words.joined(separator: " ")
    }
}
