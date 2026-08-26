import XCTest
@testable import WhisperDictCore

final class ListeningWindowTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "ListeningWindowTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    // MARK: Duration

    func testDurationsMapToIdleIntervals() {
        XCTAssertEqual(ListeningWindowDuration.off.idleInterval, 0)
        XCTAssertEqual(ListeningWindowDuration.fiveMinutes.idleInterval, 300)
        XCTAssertEqual(ListeningWindowDuration.fifteenMinutes.idleInterval, 900)
        XCTAssertEqual(ListeningWindowDuration.oneHour.idleInterval, 3600)
        XCTAssertNil(ListeningWindowDuration.always.idleInterval)
    }

    func testOnlyOffIsDisabled() {
        XCTAssertFalse(ListeningWindowDuration.off.isEnabled)
        for duration in ListeningWindowDuration.allCases where duration != .off {
            XCTAssertTrue(duration.isEnabled, "\(duration) should be enabled")
        }
    }

    // MARK: Policy

    func testWindowExpiresAfterIdleInterval() {
        let last = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(
            ListeningWindowPolicy.expiry(lastActivity: last, duration: .fiveMinutes),
            Date(timeIntervalSince1970: 1_300)
        )
        XCTAssertFalse(ListeningWindowPolicy.shouldExpire(
            now: Date(timeIntervalSince1970: 1_299), lastActivity: last, duration: .fiveMinutes
        ))
        XCTAssertTrue(ListeningWindowPolicy.shouldExpire(
            now: Date(timeIntervalSince1970: 1_300), lastActivity: last, duration: .fiveMinutes
        ))
    }

    func testAlwaysNeverExpiresOnItsOwn() {
        let last = Date(timeIntervalSince1970: 0)
        XCTAssertNil(ListeningWindowPolicy.expiry(lastActivity: last, duration: .always))
        XCTAssertFalse(ListeningWindowPolicy.shouldExpire(
            now: .distantFuture, lastActivity: last, duration: .always
        ))
    }

    func testOffExpiresImmediately() {
        let last = Date(timeIntervalSince1970: 500)
        XCTAssertTrue(ListeningWindowPolicy.shouldExpire(now: last, lastActivity: last, duration: .off))
    }

    // MARK: Shared state

    func testHeartbeatGoesStale() {
        let now = Date(timeIntervalSince1970: 10_000)
        XCTAssertFalse(ListeningWindowState.isAlive(defaults: defaults, now: now))

        ListeningWindowState.markAlive(defaults: defaults, now: now)
        XCTAssertTrue(ListeningWindowState.isAlive(defaults: defaults, now: now))
        XCTAssertTrue(ListeningWindowState.isAlive(
            defaults: defaults,
            now: now.addingTimeInterval(ListeningWindowState.staleInterval)
        ))
        XCTAssertFalse(ListeningWindowState.isAlive(
            defaults: defaults,
            now: now.addingTimeInterval(ListeningWindowState.staleInterval + 1)
        ))
    }

    func testEndingTheWindowClearsHeartbeatAndPendingRequests() {
        let now = Date(timeIntervalSince1970: 10_000)
        ListeningWindowState.markAlive(defaults: defaults, now: now)
        ListeningWindowState.requestStart(defaults: defaults)

        ListeningWindowState.end(defaults: defaults)

        XCTAssertFalse(ListeningWindowState.isAlive(defaults: defaults, now: now))
        XCTAssertFalse(ListeningWindowState.consumeStartRequest(defaults: defaults))
    }

    func testStartRequestIsConsumedExactlyOnce() {
        XCTAssertFalse(ListeningWindowState.consumeStartRequest(defaults: defaults))

        ListeningWindowState.requestStart(defaults: defaults)
        XCTAssertTrue(ListeningWindowState.consumeStartRequest(defaults: defaults))
        XCTAssertFalse(ListeningWindowState.consumeStartRequest(defaults: defaults))
    }

    func testTwoRequestsBeforeAPollCollapseIntoOneStart() {
        ListeningWindowState.requestStart(defaults: defaults)
        ListeningWindowState.requestStart(defaults: defaults)
        XCTAssertTrue(ListeningWindowState.consumeStartRequest(defaults: defaults))
        XCTAssertFalse(ListeningWindowState.consumeStartRequest(defaults: defaults))
    }

    // MARK: Signals

    func testDarwinSignalReachesAnObserver() {
        let received = expectation(description: "start signal delivered")
        let observation = DictationSignalCenter.observe(.start) { received.fulfill() }
        // Darwin notifications are delivered on the observing thread's run
        // loop; posting from here and waiting lets the main loop drain it.
        DictationSignalCenter.post(.start)
        wait(for: [received], timeout: 2)
        withExtendedLifetime(observation) {}
    }
}

final class ListeningKeyboardGuidanceTests: XCTestCase {
    func testTalkIsARealButtonOnlyWhileListening() {
        XCTAssertEqual(KeyboardHandoffGuidance.recorderAction(for: .idle, listening: true), .requestStart)
        XCTAssertEqual(KeyboardHandoffGuidance.recorderAction(for: .ready, listening: true), .requestStart)
        XCTAssertEqual(KeyboardHandoffGuidance.recorderAction(for: .idle, listening: false), .showActionButtonGuidance)
        XCTAssertEqual(KeyboardHandoffGuidance.recorderAction(for: .ready, listening: false), .showActionButtonGuidance)
    }

    func testFailureRetriesWhileListeningButExplainsOtherwise() {
        XCTAssertEqual(KeyboardHandoffGuidance.recorderAction(for: .failed, listening: true), .requestStart)
        XCTAssertEqual(KeyboardHandoffGuidance.recorderAction(for: .failed, listening: false), .showFailure)
    }

    func testStopAndWorkingDoNotDependOnListening() {
        for listening in [true, false] {
            XCTAssertEqual(KeyboardHandoffGuidance.recorderAction(for: .recording, listening: listening), .requestStop)
            XCTAssertEqual(KeyboardHandoffGuidance.recorderAction(for: .transcribing, listening: listening), .showTranscribing)
        }
    }

    func testButtonTitleReflectsCapability() {
        XCTAssertEqual(KeyboardHandoffGuidance.recorderButtonTitle(for: .idle, listening: true), "Talk")
        XCTAssertEqual(KeyboardHandoffGuidance.recorderButtonTitle(for: .idle, listening: false), "Action Button")
        XCTAssertEqual(KeyboardHandoffGuidance.recorderButtonTitle(for: .recording, listening: true), "Stop")
        XCTAssertEqual(KeyboardHandoffGuidance.recorderButtonTitle(for: .transcribing, listening: false), "Working")
    }
}
