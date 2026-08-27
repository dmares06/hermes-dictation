import Foundation

public struct SavedNote: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var title: String
    public var body: String
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        title: String,
        body: String,
        createdAt: Date = Date(),
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }
}

public enum NoteTitle {
    public static let maximumLength = 60

    /// A title derived from the first line of a note, so dictated notes read
    /// well in a list without the user naming them.
    public static func derive(from body: String) -> String {
        let firstLine = body
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first(where: { !$0.isEmpty }) ?? ""
        guard !firstLine.isEmpty else { return "Untitled note" }
        // Cut at a sentence end when there is one in range, otherwise at a
        // word boundary; never mid-word.
        if let sentenceEnd = firstLine.firstIndex(where: { ".!?".contains($0) }),
           firstLine.distance(from: firstLine.startIndex, to: sentenceEnd) < maximumLength {
            return String(firstLine[..<sentenceEnd])
        }
        guard firstLine.count > maximumLength else { return firstLine }
        let clipped = firstLine.prefix(maximumLength)
        if let lastSpace = clipped.lastIndex(of: " ") {
            return String(clipped[..<lastSpace]) + "…"
        }
        return String(clipped) + "…"
    }
}

/// Notes kept inside the app, in the app group so the keyboard could read
/// them later. iOS offers no API into Apple Notes, so this is the "notes
/// section" a dictation flow can save into without leaving.
public final class NoteStore: @unchecked Sendable {
    public static let maximumBodyLength = 8_000

    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let lock = NSLock()

    /// - Parameter directory: where `notes.json` lives. Defaults to the app
    ///   group container; tests pass a temporary directory.
    public init(directory: URL? = nil) {
        let base = directory
            ?? FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: TranscriptStore.appGroupID)
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        fileURL = base.appendingPathComponent("notes.json")
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    /// Newest first.
    public var notes: [SavedNote] {
        lock.lock(); defer { lock.unlock() }
        return load()
    }

    public func note(id: UUID) -> SavedNote? {
        notes.first { $0.id == id }
    }

    @discardableResult
    public func save(body: String, title: String? = nil, at date: Date = Date()) throws -> SavedNote {
        let cleaned = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw NoteError.empty }
        guard cleaned.count <= Self.maximumBodyLength else { throw NoteError.tooLong }
        let resolvedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let note = SavedNote(
            title: resolvedTitle.flatMap { $0.isEmpty ? nil : $0 } ?? NoteTitle.derive(from: cleaned),
            body: cleaned,
            createdAt: date
        )
        lock.lock(); defer { lock.unlock() }
        try persist([note] + load())
        return note
    }

    public func update(id: UUID, body: String, title: String? = nil, at date: Date = Date()) throws {
        let cleaned = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw NoteError.empty }
        guard cleaned.count <= Self.maximumBodyLength else { throw NoteError.tooLong }
        lock.lock(); defer { lock.unlock() }
        var all = load()
        guard let index = all.firstIndex(where: { $0.id == id }) else { throw NoteError.missing }
        let resolvedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        all[index].body = cleaned
        all[index].title = resolvedTitle.flatMap { $0.isEmpty ? nil : $0 } ?? NoteTitle.derive(from: cleaned)
        all[index].updatedAt = date
        // Editing moves a note to the top, like a notes app.
        let edited = all.remove(at: index)
        try persist([edited] + all)
    }

    public func delete(id: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        try persist(load().filter { $0.id != id })
    }

    public func search(_ query: String) -> [SavedNote] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return notes }
        return notes.filter {
            $0.title.localizedCaseInsensitiveContains(needle)
                || $0.body.localizedCaseInsensitiveContains(needle)
        }
    }

    public func clear() throws {
        lock.lock(); defer { lock.unlock() }
        try persist([])
    }

    private func load() -> [SavedNote] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? decoder.decode([SavedNote].self, from: data)) ?? []
    }

    private func persist(_ notes: [SavedNote]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encoder.encode(notes).write(to: fileURL, options: .atomic)
    }

    public enum NoteError: LocalizedError, Equatable {
        case empty
        case tooLong
        case missing

        public var errorDescription: String? {
            switch self {
            case .empty: "The note is empty."
            case .tooLong: "That note is too long. Keep it under 8,000 characters."
            case .missing: "That note no longer exists."
            }
        }
    }
}
