import XCTest
@testable import WhisperDictCore

final class KeyboardLayoutTests: XCTestCase {
    func testAlphabeticLayoutContainsEveryLetter() {
        let characters = KeyboardLayout.alphabetic.rows.prefix(3)
            .flatMap { $0 }
            .compactMap(\.insertedText)
            .joined()

        XCTAssertEqual(Set(characters), Set("abcdefghijklmnopqrstuvwxyz"))
    }

    func testNumericLayoutContainsDigitsAndPunctuation() {
        let inserted = KeyboardLayout.numeric.rows
            .flatMap { $0 }
            .compactMap(\.insertedText)

        for expected in ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", ".", ",", "?", "!"] {
            XCTAssertTrue(inserted.contains(expected), "Missing key: \(expected)")
        }
    }

    func testLetterOutputRespectsShift() {
        XCTAssertEqual(KeyboardKey.character("q").text(shifted: false), "q")
        XCTAssertEqual(KeyboardKey.character("q").text(shifted: true), "Q")
        XCTAssertNil(KeyboardKey.delete.insertedText)
    }
}
