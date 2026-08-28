import Foundation

/// Builds the block of context handed to a new Realtime session so Hermes
/// starts a conversation already knowing who he is talking to.
///
/// It is deliberately a plain string built on the phone rather than anything
/// the backend stores: the session is the only place this travels, and what
/// goes into it is exactly what the user can see and delete in the app.
public enum HermesMemoryBriefing {
    /// How many characters of facts and conversation history to carry. Enough
    /// to be useful, small enough that priming does not crowd out the
    /// conversation itself.
    public static let characterBudget = 1_800

    /// Characters kept from either side of a remembered exchange.
    static let turnExcerptLength = 140

    public static let preamble = """
        Context carried over from earlier, stored only on the user's iPhone. \
        Use it when it is relevant to what he is saying. Do not read it back as \
        a list, do not open by summarising it, and do not mention that you have \
        a memory unless he asks about it.
        """

    public static func text(
        memories: [HermesMemory],
        conversations: [HermesConversation],
        now: Date = Date(),
        budget: Int = characterBudget
    ) -> String? {
        var remaining = max(0, budget)

        // Facts are spent first: they are the durable half, and re-learning
        // them costs a whole conversation. Transcript excerpts fill what is
        // left and are the right thing to lose when the budget is tight.
        let facts = take(memories.map { "- \($0.text)" }, from: &remaining)
        let exchanges = take(conversations.compactMap { line(for: $0, now: now) }, from: &remaining)

        guard !facts.isEmpty || !exchanges.isEmpty else { return nil }

        var sections = [preamble]
        if !facts.isEmpty {
            sections.append("What you know about him:\n" + facts.joined(separator: "\n"))
        }
        if !exchanges.isEmpty {
            sections.append("What you have talked about before:\n" + exchanges.joined(separator: "\n"))
        }
        return sections.joined(separator: "\n\n")
    }

    /// Takes lines in order while they fit, then stops. It stops rather than
    /// skipping ahead so the result stays newest-first instead of becoming an
    /// arbitrary selection of whatever happened to be short.
    private static func take(_ lines: [String], from remaining: inout Int) -> [String] {
        var taken: [String] = []
        for line in lines {
            guard line.count + 1 <= remaining else { break }
            taken.append(line)
            remaining -= line.count + 1
        }
        return taken
    }

    private static func line(for conversation: HermesConversation, now: Date) -> String? {
        guard let opening = conversation.turns.first(where: { $0.role == .person })
            ?? conversation.turns.first
        else { return nil }
        let stamp = stamp(for: conversation.startedAt, now: now)
        var line = "- \(stamp) — he said \"\(excerpt(opening.text))\""
        if let reply = conversation.turns.last(where: { $0.role == .hermes }) {
            line += "; you answered \"\(excerpt(reply.text))\""
        }
        return line
    }

    private static func excerpt(_ text: String) -> String {
        let cleaned = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        guard cleaned.count > turnExcerptLength else { return cleaned }
        let clipped = cleaned.prefix(turnExcerptLength)
        guard let lastSpace = clipped.lastIndex(of: " ") else { return clipped + "…" }
        return clipped[..<lastSpace] + "…"
    }

    private static func stamp(for date: Date, now: Date) -> String {
        let calendar = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(date) { return "earlier today, \(time)" }
        if calendar.isDateInYesterday(date) { return "yesterday, \(time)" }
        let days = calendar.dateComponents([.day], from: date, to: now).day ?? 0
        if days < 7 { return "\(date.formatted(.dateTime.weekday(.wide))), \(time)" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}
