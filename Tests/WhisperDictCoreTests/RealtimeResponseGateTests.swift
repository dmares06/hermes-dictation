import XCTest
@testable import WhisperDictCore

/// The voice model may only have one response in flight. The gate decides
/// whether a `response.create` goes out now or waits for the active one.
final class RealtimeResponseGateTests: XCTestCase {
    func testFirstRequestGoesOutImmediately() {
        var gate = RealtimeResponseGate()
        XCTAssertTrue(gate.requestResponse())
        XCTAssertTrue(gate.responseActive)
    }

    func testRequestWhileActiveWaitsUntilTheActiveResponseIsDone() {
        var gate = RealtimeResponseGate()
        gate.noteResponseCreated()
        XCTAssertFalse(gate.requestResponse())
        XCTAssertTrue(gate.responsePending)
        XCTAssertTrue(gate.noteResponseDone(), "the deferred response is released when the server finishes")
        XCTAssertFalse(gate.responsePending)
        XCTAssertFalse(gate.responseActive)
    }

    func testDoneWithoutAPendingRequestReleasesNothing() {
        var gate = RealtimeResponseGate()
        gate.noteResponseCreated()
        XCTAssertFalse(gate.noteResponseDone())
    }

    func testTwoRequestsWhileActiveCollapseIntoOneDeferredResponse() {
        var gate = RealtimeResponseGate()
        XCTAssertTrue(gate.requestResponse())
        XCTAssertFalse(gate.requestResponse())
        XCTAssertFalse(gate.requestResponse())
        XCTAssertTrue(gate.noteResponseDone())
        XCTAssertFalse(gate.noteResponseDone())
    }

    func testActiveResponseErrorDefersAndDoesNotEndTheCall() {
        var gate = RealtimeResponseGate()
        // We sent response.create believing the line was free, but the user
        // had just spoken and the server already had a response going.
        _ = gate.requestResponse()
        let verdict = gate.noteError(code: "conversation_already_has_active_response", type: "invalid_request_error")
        XCTAssertEqual(verdict, .deferred)
        XCTAssertTrue(gate.responsePending)
        XCTAssertTrue(gate.responseActive)
        XCTAssertTrue(gate.noteResponseDone())
    }

    func testOurOwnBadRequestsAreLoggedNotFatal() {
        var gate = RealtimeResponseGate()
        _ = gate.requestResponse()
        XCTAssertEqual(gate.noteError(code: "response_cancel_not_active", type: "invalid_request_error"), .ignored)
        XCTAssertEqual(gate.noteError(code: nil, type: "invalid_request_error"), .ignored)
        // A rejected request means no response is coming for it.
        XCTAssertFalse(gate.responseActive)
    }

    func testSessionLossIsFatal() {
        var gate = RealtimeResponseGate()
        XCTAssertEqual(gate.noteError(code: "session_expired", type: "invalid_request_error"), .fatal)
        XCTAssertEqual(gate.noteError(code: nil, type: "server_error"), .fatal)
    }

    func testResetClearsEverything() {
        var gate = RealtimeResponseGate()
        _ = gate.requestResponse()
        _ = gate.requestResponse()
        gate.reset()
        XCTAssertFalse(gate.responseActive)
        XCTAssertFalse(gate.responsePending)
        XCTAssertTrue(gate.requestResponse())
    }
}

extension RealtimeResponseGateTests {
    func testIdleProbeSendsOnlyWhenFreeAndNeverQueues() {
        var gate = RealtimeResponseGate()
        XCTAssertTrue(gate.requestResponseIfIdle())
        XCTAssertTrue(gate.responseActive)
        XCTAssertFalse(gate.requestResponseIfIdle(), "a second one while busy is dropped")
        XCTAssertFalse(gate.responsePending, "dropped, not deferred: a progress line is stale by the time the line frees up")
        XCTAssertFalse(gate.noteResponseDone())
    }
}
