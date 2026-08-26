import XCTest
@testable import WhisperDictCore

final class MessageRecipientsTests: XCTestCase {
    func testAStoredNumberBecomesASingleRecipient() {
        XCTAssertEqual(MessageRecipients.normalize("+15555550123"), ["+15555550123"])
    }

    func testSurroundingWhitespaceIsTrimmed() {
        XCTAssertEqual(MessageRecipients.normalize("  me@example.com \n"), ["me@example.com"])
    }

    func testBlankValuesLeaveTheSheetUnaddressed() {
        XCTAssertEqual(MessageRecipients.normalize(nil), [])
        XCTAssertEqual(MessageRecipients.normalize(""), [])
        XCTAssertEqual(MessageRecipients.normalize("   \n\t"), [])
    }
}
