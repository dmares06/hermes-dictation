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

extension TranscriptStoreTests {
    func testMarkingATranscriptSentToHermesSurvivesReload() throws {
        let defaults = UserDefaults(suiteName: "TranscriptStoreTests.sentToHermes")!
        defaults.removePersistentDomain(forName: "TranscriptStoreTests.sentToHermes")
        let store = TranscriptStore(defaults: defaults)
        try store.save("Remind me to call the vet", at: Date(timeIntervalSince1970: 100))
        try store.save("Second one", at: Date(timeIntervalSince1970: 200))
        let target = try XCTUnwrap(store.history.last)
        XCTAssertNil(target.sentToHermesAt)

        let sentAt = Date(timeIntervalSince1970: 300)
        try store.markSentToHermes(id: target.id, at: sentAt)

        let reloaded = TranscriptStore(defaults: defaults)
        XCTAssertEqual(reloaded.history.last?.sentToHermesAt, sentAt)
        XCTAssertNil(reloaded.history.first?.sentToHermesAt, "only the one that was sent is marked")
        XCTAssertEqual(reloaded.latest?.sentToHermesAt, nil)
    }

    func testMarkingTheLatestTranscriptUpdatesWhatTheKeyboardInserts() throws {
        let defaults = UserDefaults(suiteName: "TranscriptStoreTests.sentToHermesLatest")!
        defaults.removePersistentDomain(forName: "TranscriptStoreTests.sentToHermesLatest")
        let store = TranscriptStore(defaults: defaults)
        try store.save("Newest", at: Date(timeIntervalSince1970: 100))
        let newest = try XCTUnwrap(store.latest)
        try store.markSentToHermes(id: newest.id, at: Date(timeIntervalSince1970: 150))
        XCTAssertEqual(store.latest?.sentToHermesAt, Date(timeIntervalSince1970: 150))
        XCTAssertEqual(store.latest?.text, "Newest")
    }

    func testOldEntriesWithoutTheFieldStillDecode() throws {
        let json = #"[{"id":"6BA7B810-9DAD-11D1-80B4-00C04FD430C8","text":"old","createdAt":0}]"#
        let decoded = try JSONDecoder().decode([SavedTranscript].self, from: Data(json.utf8))
        XCTAssertEqual(decoded.first?.text, "old")
        XCTAssertNil(decoded.first?.sentToHermesAt)
    }
}
