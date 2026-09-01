import XCTest
@testable import WhisperDictCore

final class ConversationIdleWatchTests: XCTestCase {
    func testAFreshConversationHasNotTimedOut() {
        let watch = ConversationIdleWatch(startedAt: 100)
        XCTAssertFalse(watch.hasTimedOut(at: 100))
        XCTAssertFalse(watch.hasTimedOut(at: 219))
    }

    func testQuietForTheWholeTimeoutEndsIt() {
        let watch = ConversationIdleWatch(startedAt: 100)
        XCTAssertTrue(watch.hasTimedOut(at: 220))
        XCTAssertTrue(watch.hasTimedOut(at: 400))
    }

    func testAnythingHappeningStartsTheCountAgain() {
        var watch = ConversationIdleWatch(startedAt: 100)
        watch.noteActivity(at: 200)
        XCTAssertFalse(watch.hasTimedOut(at: 300))
        XCTAssertTrue(watch.hasTimedOut(at: 320))
    }

    func testTheTimeoutIsTwoMinutes() {
        XCTAssertEqual(ConversationIdleWatch.defaultTimeout, 120)
    }

    /// A clock that jumps backwards must not end a live conversation.
    func testATimeGoingBackwardsIsNotATimeout() {
        let watch = ConversationIdleWatch(startedAt: 500)
        XCTAssertFalse(watch.hasTimedOut(at: 100))
    }
}
