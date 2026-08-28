import XCTest
@testable import WhisperDictCore

final class HermesMemoryStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("HermesMemoryStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        directory = nil
    }

    private func makeStore(limit: Int = 200) -> HermesMemoryStore {
        HermesMemoryStore(directory: directory, limit: limit)
    }

    func testRememberedFactsComeBackNewestFirst() throws {
        let store = makeStore()
        try store.remember("He drinks his coffee black", kind: .preference, at: Date(timeIntervalSince1970: 1))
        try store.remember("He is building Hermes", kind: .project, at: Date(timeIntervalSince1970: 2))

        XCTAssertEqual(store.memories.map(\.text), [
            "He is building Hermes",
            "He drinks his coffee black",
        ])
        XCTAssertEqual(store.memories.first?.kind, .project)
    }

    func testEmptyFactIsRejected() {
        let store = makeStore()
        XCTAssertThrowsError(try store.remember("   \n ", kind: .profile)) { error in
            XCTAssertEqual(error as? HermesMemoryStore.MemoryError, .empty)
        }
        XCTAssertTrue(store.memories.isEmpty)
    }

    func testOverlongFactIsRejected() {
        let store = makeStore()
        let long = String(repeating: "a", count: HermesMemoryStore.maximumTextLength + 1)
        XCTAssertThrowsError(try store.remember(long, kind: .profile)) { error in
            XCTAssertEqual(error as? HermesMemoryStore.MemoryError, .tooLong)
        }
    }

    func testRememberingTheSameFactTwiceRefreshesItRatherThanDuplicating() throws {
        let store = makeStore()
        let first = try store.remember("He drinks his coffee black", kind: .preference, at: Date(timeIntervalSince1970: 1))
        try store.remember("He is building Hermes", kind: .project, at: Date(timeIntervalSince1970: 2))
        let repeated = try store.remember("  he drinks his COFFEE black ", kind: .profile, at: Date(timeIntervalSince1970: 3))

        XCTAssertEqual(store.memories.count, 2)
        XCTAssertEqual(repeated.id, first.id, "the same fact keeps its identity")
        XCTAssertEqual(store.memories.first?.id, first.id, "and moves back to the top")
        XCTAssertEqual(store.memories.first?.kind, .profile, "the newer classification wins")
        XCTAssertEqual(store.memories.first?.updatedAt, Date(timeIntervalSince1970: 3))
        XCTAssertEqual(store.memories.first?.text, "He drinks his coffee black", "the original wording is kept")
    }

    func testDeleteRemovesOnlyTheNamedFact() throws {
        let store = makeStore()
        let kept = try store.remember("He is building Hermes", kind: .project)
        let removed = try store.remember("He drinks his coffee black", kind: .preference)

        try store.delete(id: removed.id)

        XCTAssertEqual(store.memories.map(\.id), [kept.id])
    }

    func testSearchIgnoresCaseAndEmptyQueryReturnsEverything() throws {
        let store = makeStore()
        try store.remember("He drinks his coffee black", kind: .preference)
        try store.remember("He is building Hermes", kind: .project)

        XCTAssertEqual(store.search("COFFEE").map(\.text), ["He drinks his coffee black"])
        XCTAssertEqual(store.search("  ").count, 2)
        XCTAssertTrue(store.search("bicycles").isEmpty)
    }

    func testOldestFactsFallOffTheEndOfTheLimit() throws {
        let store = makeStore(limit: 2)
        for second in 1...3 {
            try store.remember("fact \(second)", kind: .profile, at: Date(timeIntervalSince1970: TimeInterval(second)))
        }

        XCTAssertEqual(store.memories.map(\.text), ["fact 3", "fact 2"])
    }

    func testClearEmptiesTheStore() throws {
        let store = makeStore()
        try store.remember("He is building Hermes", kind: .project)

        try store.clear()

        XCTAssertTrue(store.memories.isEmpty)
    }
}
