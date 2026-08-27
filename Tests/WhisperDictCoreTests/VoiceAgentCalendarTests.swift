import XCTest
@testable import WhisperDictCore

final class VoiceAgentCalendarTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_787_000_000)

    private func draft(_ action: VoiceAgentAction?, file: StaticString = #filePath, line: UInt = #line) throws -> CalendarEventDraft {
        guard case .createCalendarEvent(let draft)? = action else {
            XCTFail("expected a calendar event, got \(String(describing: action))", file: file, line: line)
            throw XCTSkip("no event")
        }
        return draft
    }

    func testAnEventWithoutAnEndRunsForAnHour() throws {
        let event = try draft(VoiceAgentAction.validatedCalendarEvent(
            title: "Dentist",
            start: start,
            end: nil
        ))
        XCTAssertEqual(event.title, "Dentist")
        XCTAssertEqual(event.start, start)
        XCTAssertEqual(event.duration, CalendarEventDraft.defaultDuration)
        XCTAssertFalse(event.isAllDay)
    }

    func testAnAllDayEventWithoutAnEndRunsForADay() throws {
        let event = try draft(VoiceAgentAction.validatedCalendarEvent(
            title: "Flight home",
            start: start,
            end: nil,
            isAllDay: true
        ))
        XCTAssertTrue(event.isAllDay)
        XCTAssertEqual(event.duration, 60 * 60 * 24)
    }

    func testAnEndBeforeTheStartFallsBackToTheDefaultDuration() throws {
        let event = try draft(VoiceAgentAction.validatedCalendarEvent(
            title: "Standup",
            start: start,
            end: start.addingTimeInterval(-3_600)
        ))
        XCTAssertEqual(event.duration, CalendarEventDraft.defaultDuration)
    }

    func testAnAbsurdlyLongEventFallsBackRatherThanBlockingTheCalendar() throws {
        let event = try draft(VoiceAgentAction.validatedCalendarEvent(
            title: "Lunch",
            start: start,
            end: start.addingTimeInterval(CalendarEventDraft.maximumDuration + 1)
        ))
        XCTAssertEqual(event.duration, CalendarEventDraft.defaultDuration)
    }

    func testAGivenEndIsKept() throws {
        let event = try draft(VoiceAgentAction.validatedCalendarEvent(
            title: "Review",
            start: start,
            end: start.addingTimeInterval(1_800),
            location: "  Room 2  ",
            notes: "  Bring the deck  "
        ))
        XCTAssertEqual(event.duration, 1_800)
        XCTAssertEqual(event.location, "Room 2")
        XCTAssertEqual(event.notes, "Bring the deck")
    }

    func testAnEmptyOrOversizedTitleIsRejected() {
        XCTAssertNil(VoiceAgentAction.validatedCalendarEvent(title: "   ", start: start, end: nil))
        XCTAssertNil(VoiceAgentAction.validatedCalendarEvent(
            title: String(repeating: "a", count: CalendarEventDraft.maximumTitleLength + 1),
            start: start,
            end: nil
        ))
    }

    func testAnUnusableLocationIsDroppedRatherThanFailingTheEvent() throws {
        let event = try draft(VoiceAgentAction.validatedCalendarEvent(
            title: "Coffee",
            start: start,
            end: nil,
            location: String(repeating: "b", count: CalendarEventDraft.maximumLocationLength + 1)
        ))
        XCTAssertNil(event.location)
    }

    func testTheReviewTitleNamesTheCalendar() throws {
        let action = VoiceAgentAction.validatedCalendarEvent(title: "Dentist", start: start, end: nil)
        XCTAssertEqual(action?.reviewTitle, "Add calendar event")
    }

    func testTheSummaryReadsAsOneSpokenLine() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let event = try draft(VoiceAgentAction.validatedCalendarEvent(
            title: "Review",
            start: start,
            end: start.addingTimeInterval(1_800)
        ))
        let summary = event.summary(calendar: calendar)
        XCTAssertTrue(summary.hasPrefix("Review — "), summary)
        XCTAssertTrue(summary.contains("to"), summary)
    }
}
