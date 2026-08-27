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
        // NSDataDetector resolves "tomorrow" against the system clock, not
        // against `now` (see ReminderParser.extractDate), so the expectation
        // has to come from the same clock. Pinning a literal day here passes
        // only on the day it was written.
        let calendar = Calendar.current
        let startedAt = Date()
        let draft = try XCTUnwrap(ReminderParser.parse("remind me to call the dentist tomorrow at 9am", now: now))
        XCTAssertEqual(draft.title, "Call the dentist")
        let due = try XCTUnwrap(draft.dueDate)

        let expectedDays = Set(
            [startedAt, Date()]
                .compactMap { calendar.date(byAdding: .day, value: 1, to: $0) }
                .map { calendar.component(.day, from: $0) }
        )
        let parts = calendar.dateComponents([.day, .hour, .minute], from: due)
        // The set covers a midnight rollover mid-test rather than flaking.
        XCTAssertTrue(
            expectedDays.contains(try XCTUnwrap(parts.day)),
            "expected tomorrow (one of \(expectedDays.sorted())), got \(String(describing: parts.day))"
        )
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
