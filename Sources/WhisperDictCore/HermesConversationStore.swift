import Foundation

public enum HermesConversationMode: String, Codable, Equatable, Sendable {
    case realtime
    case offline
    /// Answered by a Hermes Agent gateway.
    case hermes
}

public enum HermesConversationRole: String, Codable, Equatable, Sendable {
    case person
    case hermes
}

public struct HermesConversationTurn: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let role: HermesConversationRole
    public let text: String
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        role: HermesConversationRole,
        text: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.createdAt = createdAt
    }

    public var wordCount: Int {
        text.split(whereSeparator: \Character.isWhitespace).count
    }
}

public struct HermesConversation: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let mode: HermesConversationMode
    public let startedAt: Date
    public var endedAt: Date?
    public var turns: [HermesConversationTurn]

    public init(
        id: UUID = UUID(),
        mode: HermesConversationMode,
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        turns: [HermesConversationTurn] = []
    ) {
        self.id = id
        self.mode = mode
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.turns = turns
    }

    public var personWordCount: Int {
        turns.filter { $0.role == .person }.reduce(0) { $0 + $1.wordCount }
    }

    public var totalWordCount: Int {
        turns.reduce(0) { $0 + $1.wordCount }
    }
}

public struct HermesUsageSummary: Equatable, Sendable {
    public let conversationCount: Int
    public let spokenWordCount: Int
    public let totalCapturedWordCount: Int
}

public final class HermesConversationStore: @unchecked Sendable {
    private enum Keys {
        static let history = "hermesConversationHistory"
    }

    private let defaults: UserDefaults
    private let historyLimit: Int
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(
        defaults: UserDefaults? = UserDefaults(suiteName: TranscriptStore.appGroupID),
        historyLimit: Int = 50
    ) {
        self.defaults = defaults ?? .standard
        self.historyLimit = max(1, historyLimit)
    }

    public var history: [HermesConversation] {
        guard let data = defaults.data(forKey: Keys.history) else { return [] }
        return (try? decoder.decode([HermesConversation].self, from: data)) ?? []
    }

    public func begin(
        id: UUID = UUID(),
        mode: HermesConversationMode,
        at date: Date = Date()
    ) throws {
        var conversations = history.filter { $0.id != id }
        conversations.insert(HermesConversation(id: id, mode: mode, startedAt: date), at: 0)
        try persist(Array(conversations.prefix(historyLimit)))
    }

    public func append(
        _ text: String,
        role: HermesConversationRole,
        to conversationID: UUID,
        at date: Date = Date()
    ) throws {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        var conversations = history
        guard let index = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
        conversations[index].turns.append(
            HermesConversationTurn(role: role, text: cleaned, createdAt: date)
        )
        try persist(conversations)
    }

    public func end(id conversationID: UUID, at date: Date = Date()) throws {
        var conversations = history
        guard let index = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
        conversations[index].endedAt = date
        try persist(conversations)
    }

    public func summary(dictatedWordCount: Int) -> HermesUsageSummary {
        HermesUsageSummary(
            conversationCount: history.count,
            spokenWordCount: history.reduce(0) { $0 + $1.personWordCount },
            totalCapturedWordCount: max(0, dictatedWordCount) + history.reduce(0) { $0 + $1.personWordCount }
        )
    }

    /// Removes one conversation. Deleting something that is already gone is a
    /// no-op rather than an error: the caller is a swipe on a list that may
    /// have been rewritten underneath it.
    public func delete(id conversationID: UUID) throws {
        let remaining = history.filter { $0.id != conversationID }
        guard remaining.count != history.count else { return }
        try persist(remaining)
    }

    public func clear() {
        defaults.removeObject(forKey: Keys.history)
    }

    private func persist(_ conversations: [HermesConversation]) throws {
        defaults.set(try encoder.encode(conversations), forKey: Keys.history)
    }
}
