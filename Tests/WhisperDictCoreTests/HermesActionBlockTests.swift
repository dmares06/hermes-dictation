import XCTest
@testable import WhisperDictCore

final class HermesActionBlockTests: XCTestCase {
    func testAReplyWithoutABlockIsSpokenAsIs() {
        let parsed = HermesActionBlock.extract(from: "Sure, it is 82 degrees.")
        XCTAssertEqual(parsed.spoken, "Sure, it is 82 degrees.")
        XCTAssertNil(parsed.action)
    }

    func testAMessageBlockBecomesAValidatedMessageAndIsStrippedFromSpeech() {
        let reply = """
        I've drafted that for you.
        <hermes-action>{"type": "message", "body": "Running ten minutes late, sorry!"}</hermes-action>
        Want me to open it?
        """
        let parsed = HermesActionBlock.extract(from: reply)
        XCTAssertEqual(parsed.spoken, "I've drafted that for you.\nWant me to open it?")
        XCTAssertEqual(parsed.action, .composeMessage("Running ten minutes late, sorry!"))
    }

    func testEmailBlocksHonourTheSendFlag() {
        let draft = #"{"type": "email", "recipient": "sam@example.com", "subject": "Hi", "body": "Hello", "send": true}"#
        let parsed = HermesActionBlock.extract(from: "<hermes-action>\(draft)</hermes-action>")
        guard case .sendEmail(let email)? = parsed.action else { return XCTFail("expected sendEmail, got \(String(describing: parsed.action))") }
        XCTAssertEqual(email.recipient, "sam@example.com")
        XCTAssertEqual(email.subject, "Hi")

        let drafted = HermesActionBlock.extract(from: #"<hermes-action>{"type": "email", "recipient": "sam@example.com", "subject": "Hi", "body": "Hello"}</hermes-action>"#)
        guard case .composeEmail? = drafted.action else { return XCTFail("expected composeEmail") }
    }

    func testRemindersParseAnISO8601DueDate() {
        let parsed = HermesActionBlock.extract(from: #"<hermes-action>{"type": "reminder", "title": "Call the dentist", "due": "2026-08-28T09:00:00-04:00"}</hermes-action>"#)
        guard case .createReminder(let reminder)? = parsed.action else { return XCTFail("expected reminder") }
        XCTAssertEqual(reminder.title, "Call the dentist")
        XCTAssertEqual(reminder.dueDate, ISO8601DateFormatter().date(from: "2026-08-28T09:00:00-04:00"))
    }

    func testNotesDestinationsAndShortcutsMapToExistingActions() {
        XCTAssertEqual(
            HermesActionBlock.extract(from: #"<hermes-action>{"type": "note", "body": "Buy milk"}</hermes-action>"#).action,
            .saveNote("Buy milk")
        )
        XCTAssertEqual(
            HermesActionBlock.extract(from: #"<hermes-action>{"type": "note", "body": "Buy milk", "apple": true}</hermes-action>"#).action,
            .shareNote("Buy milk")
        )
        XCTAssertEqual(
            HermesActionBlock.extract(from: #"<hermes-action>{"type": "open", "destination": "maps"}</hermes-action>"#).action,
            .open(.maps)
        )
        XCTAssertEqual(
            HermesActionBlock.extract(from: #"<hermes-action>{"type": "shortcut", "name": "Morning routine"}</hermes-action>"#).action,
            .runShortcut("Morning routine")
        )
    }

    func testInvalidBlocksAreDroppedFromSpeechButYieldNoAction() {
        let bad = HermesActionBlock.extract(from: "Here you go. <hermes-action>{not json}</hermes-action>")
        XCTAssertEqual(bad.spoken, "Here you go.")
        XCTAssertNil(bad.action)

        let unknown = HermesActionBlock.extract(from: #"<hermes-action>{"type": "launch_missiles"}</hermes-action> Done."#)
        XCTAssertEqual(unknown.spoken, "Done.")
        XCTAssertNil(unknown.action)

        let invalidEmail = HermesActionBlock.extract(from: #"<hermes-action>{"type": "email", "recipient": "not an address", "subject": "x", "body": "y"}</hermes-action>"#)
        XCTAssertNil(invalidEmail.action, "the existing validators still gate what reaches the confirmation card")
    }

    func testOnlyTheFirstBlockIsHonoured() {
        let reply = #"<hermes-action>{"type": "note", "body": "one"}</hermes-action><hermes-action>{"type": "note", "body": "two"}</hermes-action>"#
        let parsed = HermesActionBlock.extract(from: reply)
        XCTAssertEqual(parsed.action, .saveNote("one"))
        XCTAssertEqual(parsed.spoken, "")
    }
}
