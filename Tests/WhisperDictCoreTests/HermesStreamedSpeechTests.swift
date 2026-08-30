import XCTest
@testable import WhisperDictCore

final class HermesStreamedSpeechTests: XCTestCase {
    func testAPictureInTheReplyIsShownNotSpoken() {
        var speech = HermesStreamedSpeech()
        XCTAssertEqual(speech.append("Here is one. "), ["Here is one."])
        XCTAssertEqual(speech.append("![A russet potato](https://x.io/potato.jpg)"), [])
        let finished = speech.finish(completedText: nil)
        XCTAssertEqual(finished.spoken, "Here is one.")
        XCTAssertNil(finished.remainingSpeech)
        XCTAssertEqual(finished.images, [.remote(URL(string: "https://x.io/potato.jpg")!)])
    }

    func testSentencesAreSpokenAsTheyCompleteWithMarkdownStripped() {
        var speech = HermesStreamedSpeech()
        XCTAssertEqual(speech.append("It is **82** degrees"), [])
        XCTAssertEqual(speech.append(" and clear. Tomorrow "), ["It is 82 degrees and clear."])
        XCTAssertEqual(speech.append("looks the same."), [])
        XCTAssertEqual(speech.displayText, "It is 82 degrees and clear. Tomorrow looks the same.")

        let finished = speech.finish(completedText: nil)
        XCTAssertEqual(finished.spoken, "It is 82 degrees and clear. Tomorrow looks the same.", "the bubble is plain text too")
        XCTAssertEqual(finished.remainingSpeech, "Tomorrow looks the same.")
        XCTAssertNil(finished.action)
    }

    func testAnActionBlockIsNeverSpokenAndBecomesTheAction() {
        var speech = HermesStreamedSpeech()
        XCTAssertEqual(speech.append("I drafted that for you. "), ["I drafted that for you."])
        XCTAssertEqual(speech.append("<hermes-action>{\"type\": \"message\", \"body\": \"Running late. See you at 7.\"}"), [])
        XCTAssertEqual(speech.displayText, "I drafted that for you.", "a half-received block is not shown")
        XCTAssertEqual(speech.append("</hermes-action>"), [])

        let finished = speech.finish(completedText: nil)
        XCTAssertEqual(finished.spoken, "I drafted that for you.")
        XCTAssertEqual(finished.action, .composeMessage("Running late. See you at 7."))
        XCTAssertNil(finished.remainingSpeech, "the sentence before the block was already spoken")
    }

    func testTextAfterABlockIsStillSpokenAtTheEnd() {
        var speech = HermesStreamedSpeech()
        _ = speech.append("<hermes-action>{\"type\": \"note\", \"body\": \"Buy milk\"}</hermes-action>\nSaved a note for you to approve.")
        let finished = speech.finish(completedText: nil)
        XCTAssertEqual(finished.action, .saveNote("Buy milk"))
        XCTAssertEqual(finished.remainingSpeech, "Saved a note for you to approve.")
        XCTAssertEqual(finished.spoken, "Saved a note for you to approve.")
    }

    func testTheServersCopyIsUsedWhenNoDeltasArrived() {
        var speech = HermesStreamedSpeech()
        let finished = speech.finish(completedText: "All done.")
        XCTAssertEqual(finished.spoken, "All done.")
        XCTAssertEqual(finished.remainingSpeech, "All done.")
    }

    func testNothingAtAllYieldsNothing() {
        var speech = HermesStreamedSpeech()
        let finished = speech.finish(completedText: "")
        XCTAssertEqual(finished.spoken, "")
        XCTAssertNil(finished.remainingSpeech)
        XCTAssertNil(finished.action)
    }
}
