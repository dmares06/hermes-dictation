import Foundation

public enum HermesMemoryKind: String, Codable, Equatable, Sendable, CaseIterable, Identifiable {
    /// Who he is: name, family, where he lives, what he does.
    case profile
    /// How he likes things done.
    case preference
    /// Ongoing work and goals.
    case project
    /// Something that happened in an earlier conversation.
    case episode

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .profile: "About you"
        case .preference: "Preferences"
        case .project: "Projects"
        case .episode: "Things that happened"
        }
    }

    public var symbolName: String {
        switch self {
        case .profile: "person.text.rectangle"
        case .preference: "slider.horizontal.3"
        case .project: "hammer"
        case .episode: "bubble.left.and.bubble.right"
        }
    }
}

public struct HermesMemory: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var text: String
    public var kind: HermesMemoryKind
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        text: String,
        kind: HermesMemoryKind,
        createdAt: Date = Date(),
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.text = text
        self.kind = kind
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }
}

/// What Hermes has been told to remember, kept on the phone in the app group
/// beside the notes. Nothing here is uploaded except as context on a live
/// conversation, and every entry is visible and deletable in the app — memory
/// the user cannot see is memory they cannot correct.
public final class HermesMemoryStore: @unchecked Sendable {
    public static let maximumTextLength = 400

    private let fileURL: URL
    private let limit: Int
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let lock = NSLock()

    /// - Parameter directory: where `memories.json` lives. Defaults to the app
    ///   group container; tests pass a temporary directory.
    public init(directory: URL? = nil, limit: Int = 200) {
        let base = directory
            ?? FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: TranscriptStore.appGroupID)
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        fileURL = base.appendingPathComponent("memories.json")
        self.limit = max(1, limit)
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    /// Newest first.
    public var memories: [HermesMemory] {
        lock.lock(); defer { lock.unlock() }
        return load()
    }

    /// Stores one fact. Saying the same thing again refreshes what is already
    /// there rather than stacking near-duplicates: a model that re-learns a
    /// fact every session would otherwise crowd out everything else.
    @discardableResult
    public func remember(
        _ text: String,
        kind: HermesMemoryKind,
        at date: Date = Date()
    ) throws -> HermesMemory {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw MemoryError.empty }
        guard cleaned.count <= Self.maximumTextLength else { throw MemoryError.tooLong }

        lock.lock(); defer { lock.unlock() }
        var all = load()

        if let index = all.firstIndex(where: { Self.isSameFact($0.text, cleaned) }) {
            var existing = all.remove(at: index)
            existing.kind = kind
            existing.updatedAt = date
            try persist([existing] + all)
            return existing
        }

        let memory = HermesMemory(text: cleaned, kind: kind, createdAt: date)
        try persist([memory] + all)
        return memory
    }

    public func delete(id: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        try persist(load().filter { $0.id != id })
    }

    public func search(_ query: String) -> [HermesMemory] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return memories }
        return memories.filter { $0.text.localizedCaseInsensitiveContains(needle) }
    }

    public func clear() throws {
        lock.lock(); defer { lock.unlock() }
        try persist([])
    }

    private static func isSameFact(_ lhs: String, _ rhs: String) -> Bool {
        lhs.compare(rhs, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }

    private func load() -> [HermesMemory] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? decoder.decode([HermesMemory].self, from: data)) ?? []
    }

    private func persist(_ memories: [HermesMemory]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encoder.encode(Array(memories.prefix(limit))).write(to: fileURL, options: .atomic)
    }

    public enum MemoryError: LocalizedError, Equatable {
        case empty
        case tooLong

        public var errorDescription: String? {
            switch self {
            case .empty: "There was nothing to remember."
            case .tooLong: "That is too long to remember. Keep it under 400 characters."
            }
        }
    }
}
