import Foundation

public struct SavedTranscript: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let text: String
    public let createdAt: Date

    public init(id: UUID = UUID(), text: String, createdAt: Date) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
    }
}

public final class TranscriptStore: @unchecked Sendable {
    public static let appGroupID = "group.com.dmares06.whisperdict"

    private enum Keys {
        static let history = "transcriptHistory"
        static let latest = "latestTranscript"
    }

    private let defaults: UserDefaults
    private let historyLimit: Int
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(
        defaults: UserDefaults? = UserDefaults(suiteName: TranscriptStore.appGroupID),
        historyLimit: Int = 20
    ) {
        self.defaults = defaults ?? .standard
        self.historyLimit = max(1, historyLimit)
    }

    public var latest: SavedTranscript? {
        guard let data = defaults.data(forKey: Keys.latest) else { return nil }
        return try? decoder.decode(SavedTranscript.self, from: data)
    }

    public var history: [SavedTranscript] {
        guard let data = defaults.data(forKey: Keys.history) else { return [] }
        return (try? decoder.decode([SavedTranscript].self, from: data)) ?? []
    }

    public func save(_ text: String, at date: Date = Date()) throws {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }

        let transcript = SavedTranscript(text: cleaned, createdAt: date)
        let updatedHistory = Array(([transcript] + history).prefix(historyLimit))
        defaults.set(try encoder.encode(transcript), forKey: Keys.latest)
        defaults.set(try encoder.encode(updatedHistory), forKey: Keys.history)
    }

    /// Removes one transcript. `latest` — what the keyboard inserts — follows
    /// the newest remaining entry so a deleted dictation cannot resurface.
    public func delete(id: UUID) throws {
        let remaining = history.filter { $0.id != id }
        defaults.set(try encoder.encode(remaining), forKey: Keys.history)
        guard latest?.id == id else { return }
        if let newest = remaining.first {
            defaults.set(try encoder.encode(newest), forKey: Keys.latest)
        } else {
            defaults.removeObject(forKey: Keys.latest)
        }
    }

    public func clear() {
        defaults.removeObject(forKey: Keys.latest)
        defaults.removeObject(forKey: Keys.history)
    }
}
