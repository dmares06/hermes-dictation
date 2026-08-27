import XCTest
@testable import WhisperDictCore

final class VoiceAgentNotesAndRemindersTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_787_000_000)

    func testPlainNoteRequestSavesInsideHermes() {
        var session = VoiceAgentSession()
        XCTAssertEqual(session.receive("Take a note").assistantMessage, "What should the note say?")
        let turn = session.receive("Order more coffee filters.")
        XCTAssertEqual(session.pendingAction, .saveNote("Order more coffee filters."))
        XCTAssertTrue(turn.assistantMessage.contains("save it in Hermes"))

        let confirmed = session.confirm()
        XCTAssertEqual(confirmed.action, .saveNote("Order more coffee filters."))
        XCTAssertEqual(session.step, .idle)
    }

    func testAskingForAppleNotesStillUsesTheShareSheet() {
        var session = VoiceAgentSession()
        _ = session.receive("Write a note in Apple Notes")
        XCTAssertEqual(session.step, .collectingAppleNote)
        _ = session.receive("Pick up medicine at five.")
        XCTAssertEqual(session.pendingAction, .shareNote("Pick up medicine at five."))
    }

    func testReminderWithoutADateGoesStraightToConfirmation() {
        var session = VoiceAgentSession()
        let turn = session.receive("Remind me to call the landlord", now: now)
        XCTAssertEqual(session.pendingAction, .createReminder(ReminderDraft(title: "Call the landlord")))
        XCTAssertEqual(turn.assistantMessage, "I'll remind you to call the landlord. Say confirm to add it.")
    }

    func testReminderWithADateKeepsTheDate() throws {
        var session = VoiceAgentSession()
        _ = session.receive("Remind me to submit the invoice tomorrow at 3pm", now: now)
        guard case .createReminder(let draft)? = session.pendingAction else {
            return XCTFail("expected a reminder, got \(String(describing: session.pendingAction))")
        }
        XCTAssertEqual(draft.title, "Submit the invoice")
        XCTAssertNotNil(draft.dueDate)
    }

    func testReminderWithNothingToRememberAsks() {
        var session = VoiceAgentSession()
        let turn = session.receive("Set a reminder", now: now)
        XCTAssertNil(session.pendingAction)
        XCTAssertEqual(turn.assistantMessage, "What should I remind you about?")
    }

    func testValidatorsBoundInput() {
        XCTAssertEqual(VoiceAgentAction.validatedSavedNote("  Hi  "), .saveNote("Hi"))
        XCTAssertNil(VoiceAgentAction.validatedSavedNote(String(repeating: "a", count: VoiceAgentLimits.note + 1)))
        XCTAssertEqual(
            VoiceAgentAction.validatedReminder(title: "Call", dueDate: nil),
            .createReminder(ReminderDraft(title: "Call"))
        )
        XCTAssertNil(VoiceAgentAction.validatedReminder(
            title: String(repeating: "a", count: ReminderDraft.maximumTitleLength + 1),
            dueDate: nil
        ))
    }
}
