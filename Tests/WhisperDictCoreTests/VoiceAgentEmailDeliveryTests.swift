import XCTest
@testable import WhisperDictCore

final class VoiceAgentEmailDeliveryTests: XCTestCase {
    private func draftAnEmail(_ session: inout VoiceAgentSession) {
        _ = session.receive("Compose an email")
        _ = session.receive("sam at example dot com")
        _ = session.receive("Thursday")
        _ = session.receive("See you at three.")
    }

    func testDefaultDeliveryOpensADraftInTheMailApp() {
        var session = VoiceAgentSession()
        draftAnEmail(&session)
        XCTAssertEqual(
            session.pendingAction,
            .composeEmail(EmailDraft(recipient: "sam@example.com", subject: "Thursday", body: "See you at three."))
        )
    }

    func testGmailDeliveryProducesASendAction() {
        var session = VoiceAgentSession()
        session.emailDelivery = .gmail
        draftAnEmail(&session)
        guard case .sendEmail(let draft)? = session.pendingAction else {
            return XCTFail("expected sendEmail, got \(String(describing: session.pendingAction))")
        }
        XCTAssertEqual(draft.recipient, "sam@example.com")
        let confirmed = session.confirm()
        XCTAssertEqual(confirmed.assistantMessage, "Sending the email to sam@example.com through Gmail.")
        XCTAssertEqual(confirmed.action, .sendEmail(draft))
    }

    func testRetargetingFollowsTheUsersPreference() {
        let draft = EmailDraft(recipient: "a@b.co", subject: "s", body: "b")
        XCTAssertEqual(VoiceAgentAction.sendEmail(draft).retargetedEmail(to: .mailApp), .composeEmail(draft))
        XCTAssertEqual(VoiceAgentAction.composeEmail(draft).retargetedEmail(to: .gmail), .sendEmail(draft))
        XCTAssertEqual(VoiceAgentAction.sendEmail(draft).retargetedEmail(to: .gmail), .sendEmail(draft))
        XCTAssertEqual(VoiceAgentAction.saveNote("x").retargetedEmail(to: .gmail), .saveNote("x"))
    }

    func testSentEmailValidationSharesTheDraftRules() {
        XCTAssertEqual(
            VoiceAgentAction.validatedSentEmail(recipient: "sam at example dot com", subject: "Hi", body: "Body"),
            .sendEmail(EmailDraft(recipient: "sam@example.com", subject: "Hi", body: "Body"))
        )
        XCTAssertNil(VoiceAgentAction.validatedSentEmail(recipient: "not an address", subject: "Hi", body: "Body"))
    }
}
