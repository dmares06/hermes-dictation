import XCTest
@testable import WhisperDictCore

final class KeyboardTextProcessorTests: XCTestCase {
    func testPunctuationReplacesASpaceBeforeTheCursor() {
        XCTAssertEqual(
            KeyboardTextProcessor.edit(for: ".", contextBeforeInput: "Hello "),
            KeyboardTextEdit(deleteBackwardCount: 1, insertedText: ".")
        )
        XCTAssertEqual(
            KeyboardTextProcessor.edit(for: ",", contextBeforeInput: "Hello "),
            KeyboardTextEdit(deleteBackwardCount: 1, insertedText: ",")
        )
        XCTAssertEqual(
            KeyboardTextProcessor.edit(for: "?", contextBeforeInput: "Hello   "),
            KeyboardTextEdit(deleteBackwardCount: 3, insertedText: "?")
        )
    }

    func testPunctuationDoesNotRemoveWordCharacters() {
        XCTAssertEqual(
            KeyboardTextProcessor.edit(for: "!", contextBeforeInput: "Hello"),
            KeyboardTextEdit(deleteBackwardCount: 0, insertedText: "!")
        )
    }

    func testDoubleSpaceAfterAWordCreatesSentencePunctuation() {
        XCTAssertEqual(
            KeyboardTextProcessor.edit(for: " ", contextBeforeInput: "Hello "),
            KeyboardTextEdit(deleteBackwardCount: 1, insertedText: ". ")
        )
    }

    func testDoubleSpaceAfterPunctuationDoesNotAddAnotherSpace() {
        XCTAssertEqual(
            KeyboardTextProcessor.edit(for: " ", contextBeforeInput: "Hello. "),
            KeyboardTextEdit(deleteBackwardCount: 0, insertedText: "")
        )
    }

    func testRegularCharactersAndReturnsPassThrough() {
        XCTAssertEqual(
            KeyboardTextProcessor.edit(for: "a", contextBeforeInput: "Hello "),
            KeyboardTextEdit(deleteBackwardCount: 0, insertedText: "a")
        )
        XCTAssertEqual(
            KeyboardTextProcessor.edit(for: "\n", contextBeforeInput: "Hello"),
            KeyboardTextEdit(deleteBackwardCount: 0, insertedText: "\n")
        )
    }

    func testMissingDocumentContextFallsBackToPlainInsertion() {
        XCTAssertEqual(
            KeyboardTextProcessor.edit(for: ".", contextBeforeInput: nil),
            KeyboardTextEdit(deleteBackwardCount: 0, insertedText: ".")
        )
        XCTAssertEqual(
            KeyboardTextProcessor.edit(for: " ", contextBeforeInput: nil),
            KeyboardTextEdit(deleteBackwardCount: 0, insertedText: " ")
        )
    }
}
