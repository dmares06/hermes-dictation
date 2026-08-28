import XCTest
@testable import WhisperDictCore

final class TranscriptStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "TranscriptStoreTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testSavePublishesLatestAndNewestFirstHistory() throws {
        let store = TranscriptStore(defaults: defaults, historyLimit: 3)
        try store.save("First", at: Date(timeIntervalSince1970: 1))
        try store.save("Second", at: Date(timeIntervalSince1970: 2))

        XCTAssertEqual(store.latest?.text, "Second")
        XCTAssertEqual(store.history.map(\.text), ["Second", "First"])
    }

    func testDeletingOneTranscriptKeepsTheRestAndRepairsLatest() throws {
        let store = TranscriptStore(defaults: defaults, historyLimit: 5)
        try store.save("First", at: Date(timeIntervalSince1970: 1))
        try store.save("Second", at: Date(timeIntervalSince1970: 2))
        try store.save("Third", at: Date(timeIntervalSince1970: 3))
        let middle = store.history[1]

        try store.delete(id: middle.id)
        XCTAssertEqual(store.history.map(\.text), ["Third", "First"])
        XCTAssertEqual(store.latest?.text, "Third", "deleting an older entry leaves the latest alone")

        try store.delete(id: store.history[0].id)
        XCTAssertEqual(store.history.map(\.text), ["First"])
        XCTAssertEqual(store.latest?.text, "First", "deleting the latest promotes the next newest")

        try store.delete(id: store.history[0].id)
        XCTAssertTrue(store.history.isEmpty)
        XCTAssertNil(store.latest)
        XCTAssertNoThrow(try store.delete(id: UUID()), "an unknown id is a no-op")
    }

    func testHistoryIsBounded() throws {
        let store = TranscriptStore(defaults: defaults, historyLimit: 2)
        try store.save("One", at: Date(timeIntervalSince1970: 1))
        try store.save("Two", at: Date(timeIntervalSince1970: 2))
        try store.save("Three", at: Date(timeIntervalSince1970: 3))

        XCTAssertEqual(store.history.map(\.text), ["Three", "Two"])
    }

    func testBlankTranscriptsAreIgnored() throws {
        let store = TranscriptStore(defaults: defaults)
        try store.save("  \n ")

        XCTAssertNil(store.latest)
        XCTAssertTrue(store.history.isEmpty)
    }

    func testDeleteHistoryAlsoClearsLatest() throws {
        let store = TranscriptStore(defaults: defaults)
        try store.save("Something")
        store.clear()

        XCTAssertNil(store.latest)
        XCTAssertTrue(store.history.isEmpty)
    }
}
