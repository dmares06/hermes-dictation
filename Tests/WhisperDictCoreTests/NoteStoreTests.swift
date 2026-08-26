import XCTest
@testable import WhisperDictCore

final class NoteStoreTests: XCTestCase {
    private var directory: URL!
    private var store: NoteStore!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NoteStoreTests-\(UUID().uuidString)")
        store = NoteStore(directory: directory)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    func testSavedNotesComeBackNewestFirst() throws {
        let first = try store.save(body: "First thought", at: Date(timeIntervalSince1970: 100))
        let second = try store.save(body: "Second thought", at: Date(timeIntervalSince1970: 200))
        XCTAssertEqual(store.notes.map(\.id), [second.id, first.id])
    }

    func testTitleIsDerivedFromTheFirstSentence() throws {
        let note = try store.save(body: "Buy milk and eggs. Also call the plumber about the leak.")
        XCTAssertEqual(note.title, "Buy milk and eggs")
    }

    func testExplicitTitleWins() throws {
        let note = try store.save(body: "Some body text", title: "Groceries")
        XCTAssertEqual(note.title, "Groceries")
    }

    func testEmptyAndOversizedNotesAreRejected() {
        XCTAssertThrowsError(try store.save(body: "   \n"))
        XCTAssertThrowsError(try store.save(body: String(repeating: "a", count: NoteStore.maximumBodyLength + 1)))
        XCTAssertTrue(store.notes.isEmpty)
    }

    func testUpdatingMovesTheNoteToTheTopAndRederivesTheTitle() throws {
        let older = try store.save(body: "Older", at: Date(timeIntervalSince1970: 100))
        _ = try store.save(body: "Newer", at: Date(timeIntervalSince1970: 200))

        try store.update(id: older.id, body: "Older, but edited now.", at: Date(timeIntervalSince1970: 300))

        let notes = store.notes
        XCTAssertEqual(notes.first?.id, older.id)
        XCTAssertEqual(notes.first?.title, "Older, but edited now")
        XCTAssertEqual(notes.first?.updatedAt, Date(timeIntervalSince1970: 300))
        XCTAssertEqual(notes.first?.createdAt, Date(timeIntervalSince1970: 100))
    }

    func testDeleteAndSearch() throws {
        let keep = try store.save(body: "Dentist appointment on Friday")
        let drop = try store.save(body: "Throwaway")
        try store.delete(id: drop.id)

        XCTAssertEqual(store.notes.map(\.id), [keep.id])
        XCTAssertEqual(store.search("dentist").map(\.id), [keep.id])
        XCTAssertTrue(store.search("throwaway").isEmpty)
        XCTAssertEqual(store.search("   ").count, 1, "blank query lists everything")
    }

    func testNotesPersistAcrossInstances() throws {
        _ = try store.save(body: "Survives a relaunch")
        let reopened = NoteStore(directory: directory)
        XCTAssertEqual(reopened.notes.first?.body, "Survives a relaunch")
    }

    func testLongFirstLineIsClippedAtAWordBoundary() {
        let title = NoteTitle.derive(from: String(repeating: "word ", count: 30))
        XCTAssertLessThanOrEqual(title.count, NoteTitle.maximumLength + 1)
        XCTAssertTrue(title.hasSuffix("…"))
        let words = title.dropLast().split(separator: " ")
        XCTAssertTrue(words.allSatisfy { $0 == "word" }, "must not cut mid-word: \(title)")
    }
}
