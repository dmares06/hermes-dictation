import XCTest
@testable import WhisperDictCore

final class HermesDictationHandoffTests: XCTestCase {
    func testRequestTellsHermesWhereTheTextCameFrom() {
        let request = HermesDictationHandoff.request(for: "  Remind me to call the vet tomorrow at nine.  ")
        XCTAssertTrue(request.hasPrefix("I dictated this on my phone and I'm sending it to you:"))
        XCTAssertTrue(request.contains("Remind me to call the vet tomorrow at nine."))
        XCTAssertFalse(request.contains("  Remind"), "surrounding whitespace is dropped")
        XCTAssertTrue(request.contains("ask me what I want done with it"))
    }

    func testMilestoneAndBadgeCopy() {
        XCTAssertEqual(HermesDictationHandoff.milestone, "Dictation sent to Hermes")
        XCTAssertEqual(HermesDictationHandoff.badge, "Sent to Hermes")
    }
}
