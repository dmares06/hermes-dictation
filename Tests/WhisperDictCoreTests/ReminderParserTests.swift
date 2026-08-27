import XCTest
@testable import WhisperDictCore

final class ReminderParserTests: XCTestCase {
    /// A fixed "now" so relative phrases resolve deterministically.
    private let now: Date = {
        var components = DateComponents()
        components.year = 2026; components.month = 8; components.day = 26
        components.hour = 10; components.minute = 0
        return Calendar.current.date(from: components)!
    }()

    func testLeadInIsStrippedAndTitleCapitalized() {
        let draft = ReminderParser.parse("remind me to call mom", now: now)
        XCTAssertEqual(draft?.title, "Call mom")
        XCTAssertNil(draft?.dueDate)
    }

    func testRelativeDayAndTimeBecomeADueDate() throws {
        let draft = try XCTUnwrap(ReminderParser.parse("remind me to call the dentist tomorrow at 9am", now: now))
        XCTAssertEqual(draft.title, "Call the dentist")
        let due = try XCTUnwrap(draft.dueDate)
        let parts = Calendar.current.dateComponents([.day, .hour, .minute], from: due)
        XCTAssertEqual(parts.day, 27)
        XCTAssertEqual(parts.hour, 9)
        XCTAssertEqual(parts.minute, 0)
    }

    func testDanglingConnectiveIsRemovedWithTheDate() throws {
        let draft = try XCTUnwrap(ReminderParser.parse("set a reminder to take out the trash on Friday", now: now))
        XCTAssertEqual(draft.title, "Take out the trash")
        XCTAssertNotNil(draft.dueDate)
    }

    func testTrailingPunctuationIsDropped() {
        XCTAssertEqual(ReminderParser.parse("Remind me to water the plants.", now: now)?.title, "Water the plants")
    }

    func testEmptyOrOnlyLeadInIsRejected() {
        XCTAssertNil(ReminderParser.parse("remind me to", now: now))
        XCTAssertNil(ReminderParser.parse("   ", now: now))
    }

    func testOverlongTitleIsRejected() {
        let long = "remind me to " + String(repeating: "x", count: ReminderDraft.maximumTitleLength + 1)
        XCTAssertNil(ReminderParser.parse(long, now: now))
    }
}
