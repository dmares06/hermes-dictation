import XCTest
@testable import WhisperDictCore

final class HermesVoiceRelayTests: XCTestCase {
    func testAPlainReplyIsHandedToTheVoiceUnchanged() {
        let result = HermesVoiceRelay.toolOutput(fromReply: "It is 82 degrees and sunny.")
        XCTAssertEqual(result.output, "It is 82 degrees and sunny.")
        XCTAssertNil(result.action)
    }

    func testMarkdownIsFlattenedBeforeItIsSpoken() {
        let result = HermesVoiceRelay.toolOutput(fromReply: "**Two** things:\n- coffee\n- milk")
        XCTAssertFalse(result.output.contains("**"))
        XCTAssertFalse(result.output.contains("- "))
        XCTAssertTrue(result.output.contains("coffee"))
    }

    func testAnActionBlockBecomesAPendingActionAndAnApprovalNote() {
        let reply = """
        I've written that for you.
        <hermes-action>{"type":"message","body":"Running late, sorry!"}</hermes-action>
        """
        let result = HermesVoiceRelay.toolOutput(fromReply: reply)
        XCTAssertEqual(result.action, .composeMessage("Running late, sorry!"))
        XCTAssertTrue(result.output.hasPrefix("I've written that for you."))
        XCTAssertTrue(result.output.contains(HermesVoiceRelay.approvalNote))
    }

    func testAnActionWithNothingToSayStillTellsTheVoiceWhatIsOnScreen() {
        let reply = #"<hermes-action>{"type":"open","destination":"maps"}</hermes-action>"#
        let result = HermesVoiceRelay.toolOutput(fromReply: reply)
        XCTAssertEqual(result.action, .open(.maps))
        XCTAssertTrue(result.output.contains("approve"))
        XCTAssertTrue(result.output.contains(HermesVoiceRelay.approvalNote))
    }

    func testAnEmptyReplyIsReportedRatherThanSpokenAsSilence() {
        let result = HermesVoiceRelay.toolOutput(fromReply: "  \n ")
        XCTAssertNil(result.action)
        XCTAssertFalse(result.output.isEmpty)
    }

    func testAFailureIsPhrasedForTheVoiceToRelay() {
        let output = HermesVoiceRelay.failureOutput("the Mac is asleep")
        XCTAssertTrue(output.contains("the Mac is asleep"))
        XCTAssertTrue(output.lowercased().contains("could not"))
    }

    func testTheRequestIsTakenFromTheToolArguments() {
        XCTAssertEqual(HermesVoiceRelay.request(from: ["request": "  what's on today? "]), "what's on today?")
        XCTAssertNil(HermesVoiceRelay.request(from: ["request": "   "]))
        XCTAssertNil(HermesVoiceRelay.request(from: [:]))
    }
}
