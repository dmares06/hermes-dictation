import XCTest
@testable import WhisperDictCore

/// While Hermes runs a tool the caller hears silence; the narrator picks
/// the short spoken line for the first tool of a turn, and holds back
/// repeats so a five-tool turn is not five interruptions.
final class HermesProgressNarratorTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000)

    func testKnownToolsGetAShortSpokenLine() {
        XCTAssertEqual(HermesProgressNarrator.line(forTool: "web_search"), "Searching the web now.")
        XCTAssertEqual(HermesProgressNarrator.line(forTool: "web_extract"), "Reading a page.")
        XCTAssertEqual(HermesProgressNarrator.line(forTool: "mcp__flights__search_flights"), "Checking flights now.")
        XCTAssertEqual(HermesProgressNarrator.line(forTool: "mcp__flights__return_flights"), "Checking flights now.")
        XCTAssertEqual(HermesProgressNarrator.line(forTool: "browser_navigate"), "Opening the browser.")
        XCTAssertEqual(HermesProgressNarrator.line(forTool: "session_search"), "Checking my memory.")
        XCTAssertEqual(HermesProgressNarrator.line(forTool: "brv_query"), "Checking my memory.")
    }

    func testHousekeepingToolsAreSilent() {
        for tool in ["tool_search", "tool_describe", "tool_call", "skill_view", "skills_list", "todo", "memory_note"] {
            XCTAssertNil(HermesProgressNarrator.line(forTool: tool), tool)
        }
    }

    func testUnknownToolsGetAGenericLine() {
        XCTAssertEqual(HermesProgressNarrator.line(forTool: "mcp__calendar__list_events"), "Working on it.")
    }

    func testFirstNarratableToolSpeaksAtOnce() {
        var narrator = HermesProgressNarrator()
        XCTAssertNil(narrator.narration(forTool: "tool_search", at: start))
        XCTAssertEqual(narrator.narration(forTool: "mcp__flights__search_flights", at: start.addingTimeInterval(1)), "Checking flights now.")
    }

    func testSameLineIsNotRepeatedWithinTheHoldOff() {
        var narrator = HermesProgressNarrator()
        _ = narrator.narration(forTool: "web_search", at: start)
        XCTAssertNil(narrator.narration(forTool: "web_search", at: start.addingTimeInterval(3)))
        XCTAssertNil(narrator.narration(forTool: "web_search", at: start.addingTimeInterval(7)), "still the same activity")
    }

    func testADifferentActivitySpeaksAfterTheHoldOff() {
        var narrator = HermesProgressNarrator()
        _ = narrator.narration(forTool: "web_search", at: start)
        XCTAssertNil(narrator.narration(forTool: "web_extract", at: start.addingTimeInterval(2)), "too soon after the last line")
        XCTAssertEqual(narrator.narration(forTool: "web_extract", at: start.addingTimeInterval(9)), "Reading a page.")
    }

    func testResetForgetsTheLastTurn() {
        var narrator = HermesProgressNarrator()
        _ = narrator.narration(forTool: "web_search", at: start)
        narrator.reset()
        XCTAssertEqual(narrator.narration(forTool: "web_search", at: start.addingTimeInterval(1)), "Searching the web now.")
    }
}
