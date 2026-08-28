import XCTest
@testable import WhisperDictCore

final class HermesMemoryBriefingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func memory(_ text: String, _ kind: HermesMemoryKind = .profile, secondsAgo: TimeInterval) -> HermesMemory {
        HermesMemory(text: text, kind: kind, createdAt: now.addingTimeInterval(-secondsAgo))
    }

    private func conversation(
        _ turns: [(HermesConversationRole, String)],
        secondsAgo: TimeInterval = 3_600
    ) -> HermesConversation {
        let startedAt = now.addingTimeInterval(-secondsAgo)
        return HermesConversation(
            mode: .realtime,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(60),
            turns: turns.map { HermesConversationTurn(role: $0.0, text: $0.1, createdAt: startedAt) }
        )
    }

    func testNothingRememberedProducesNoBriefing() {
        XCTAssertNil(HermesMemoryBriefing.text(memories: [], conversations: [], now: now))
    }

    func testConversationsWithNoTurnsAreNotWorthCarryingOver() {
        let briefing = HermesMemoryBriefing.text(
            memories: [],
            conversations: [conversation([])],
            now: now
        )
        XCTAssertNil(briefing)
    }

    func testFactsAreListedNewestFirst() throws {
        let briefing = try XCTUnwrap(HermesMemoryBriefing.text(
            memories: [
                memory("He is building Hermes", .project, secondsAgo: 10),
                memory("He drinks his coffee black", .preference, secondsAgo: 100),
            ],
            conversations: [],
            now: now
        ))

        let hermes = try XCTUnwrap(briefing.range(of: "He is building Hermes"))
        let coffee = try XCTUnwrap(briefing.range(of: "He drinks his coffee black"))
        XCTAssertLessThan(hermes.lowerBound, coffee.lowerBound)
    }

    func testEarlierConversationsCarryBothSides() throws {
        let briefing = try XCTUnwrap(HermesMemoryBriefing.text(
            memories: [],
            conversations: [conversation([
                (.person, "What is the weather"),
                (.hermes, "Eighty-two and clear"),
            ])],
            now: now
        ))

        XCTAssertTrue(briefing.contains("What is the weather"))
        XCTAssertTrue(briefing.contains("Eighty-two and clear"))
    }

    func testATightBudgetKeepsFactsAndDropsConversations() throws {
        let briefing = try XCTUnwrap(HermesMemoryBriefing.text(
            memories: [memory("He drinks his coffee black", .preference, secondsAgo: 10)],
            conversations: [conversation([(.person, "What is the weather"), (.hermes, "Clear")])],
            now: now,
            budget: 40
        ))

        XCTAssertTrue(briefing.contains("He drinks his coffee black"))
        XCTAssertFalse(briefing.contains("What is the weather"))
    }

    func testLongTurnsAreShortenedRatherThanCarriedWhole() throws {
        let sentence = String(repeating: "word ", count: 200)
        let briefing = try XCTUnwrap(HermesMemoryBriefing.text(
            memories: [],
            conversations: [conversation([(.person, sentence), (.hermes, "Understood")])],
            now: now
        ))

        XCTAssertLessThan(briefing.count, sentence.count)
        XCTAssertTrue(briefing.contains("…"))
    }

    func testTheBriefingStaysWithinItsBudget() throws {
        let memories = (1...80).map { memory("Fact number \($0) about him", .profile, secondsAgo: TimeInterval($0)) }
        let conversations = (1...20).map { index in
            conversation(
                [(.person, "Question \(index)"), (.hermes, "Answer \(index)")],
                secondsAgo: TimeInterval(index) * 3_600
            )
        }

        let briefing = try XCTUnwrap(HermesMemoryBriefing.text(
            memories: memories,
            conversations: conversations,
            now: now,
            budget: 600
        ))

        XCTAssertLessThanOrEqual(briefing.count, 600 + HermesMemoryBriefing.preamble.count + 80)
    }
}
