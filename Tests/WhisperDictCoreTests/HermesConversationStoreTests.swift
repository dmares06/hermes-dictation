import XCTest
@testable import WhisperDictCore

final class HermesConversationStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "HermesConversationStoreTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testConversationPersistsTurnsAndWordCounts() throws {
        let store = HermesConversationStore(defaults: defaults)
        let id = UUID()

        try store.begin(id: id, mode: .realtime, at: Date(timeIntervalSince1970: 10))
        try store.append("  Hello there  ", role: .person, to: id, at: Date(timeIntervalSince1970: 11))
        try store.append("Hi. How can I help?", role: .hermes, to: id, at: Date(timeIntervalSince1970: 12))
        try store.end(id: id, at: Date(timeIntervalSince1970: 13))

        let conversation = try XCTUnwrap(store.history.first)
        XCTAssertEqual(conversation.id, id)
        XCTAssertEqual(conversation.mode, .realtime)
        XCTAssertEqual(conversation.turns.map(\.text), ["Hello there", "Hi. How can I help?"])
        XCTAssertEqual(conversation.personWordCount, 2)
        XCTAssertEqual(conversation.totalWordCount, 7)
        XCTAssertEqual(conversation.endedAt, Date(timeIntervalSince1970: 13))
    }

    func testBlankTurnsAreIgnored() throws {
        let store = HermesConversationStore(defaults: defaults)
        let id = UUID()
        try store.begin(id: id, mode: .offline)

        try store.append(" \n ", role: .person, to: id)

        XCTAssertTrue(try XCTUnwrap(store.history.first).turns.isEmpty)
    }

    func testNewestConversationsAreBounded() throws {
        let store = HermesConversationStore(defaults: defaults, historyLimit: 2)
        for second in 1...3 {
            try store.begin(
                id: UUID(),
                mode: .realtime,
                at: Date(timeIntervalSince1970: TimeInterval(second))
            )
        }

        XCTAssertEqual(store.history.count, 2)
        XCTAssertEqual(store.history.map(\.startedAt), [
            Date(timeIntervalSince1970: 3),
            Date(timeIntervalSince1970: 2),
        ])
    }

    func testSummaryCombinesConversationAndDictationUsage() throws {
        let store = HermesConversationStore(defaults: defaults)
        let id = UUID()
        try store.begin(id: id, mode: .realtime)
        try store.append("one two three", role: .person, to: id)
        try store.append("four five", role: .hermes, to: id)

        let summary = store.summary(dictatedWordCount: 8)

        XCTAssertEqual(summary.conversationCount, 1)
        XCTAssertEqual(summary.spokenWordCount, 3)
        XCTAssertEqual(summary.totalCapturedWordCount, 11)
    }

    func testClearRemovesConversationHistory() throws {
        let store = HermesConversationStore(defaults: defaults)
        try store.begin(id: UUID(), mode: .realtime)

        store.clear()

        XCTAssertTrue(store.history.isEmpty)
    }

    func testDeleteRemovesOnlyTheNamedConversation() throws {
        let store = HermesConversationStore(defaults: defaults)
        let kept = UUID()
        let removed = UUID()
        try store.begin(id: kept, mode: .realtime, at: Date(timeIntervalSince1970: 1))
        try store.begin(id: removed, mode: .offline, at: Date(timeIntervalSince1970: 2))
        try store.append("keep this", role: .person, to: kept)

        try store.delete(id: removed)

        XCTAssertEqual(store.history.map(\.id), [kept])
        XCTAssertEqual(store.history.first?.turns.first?.text, "keep this")
    }

    func testDeletingAnUnknownConversationLeavesHistoryAlone() throws {
        let store = HermesConversationStore(defaults: defaults)
        let id = UUID()
        try store.begin(id: id, mode: .realtime)

        try store.delete(id: UUID())

        XCTAssertEqual(store.history.map(\.id), [id])
    }
}
