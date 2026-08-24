import XCTest
@testable import WhisperDictCore

final class BackgroundDictationStateTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "BackgroundDictationStateTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testRecordingCanBeStoppedAndFinishedForKeyboardInsertion() {
        let startedAt = Date(timeIntervalSince1970: 100)
        let revision = Date(timeIntervalSince1970: 200)

        BackgroundDictationState.begin(defaults: defaults, now: startedAt)
        XCTAssertEqual(BackgroundDictationState.phase(defaults: defaults), .recording)
        XCTAssertEqual(defaults.double(forKey: BackgroundDictationState.Keys.startedAt), 100)
        XCTAssertFalse(BackgroundDictationState.shouldStop(defaults: defaults))

        BackgroundDictationState.requestStop(defaults: defaults)
        XCTAssertTrue(BackgroundDictationState.shouldStop(defaults: defaults))

        BackgroundDictationState.setPhase(.transcribing, defaults: defaults)
        BackgroundDictationState.finish(transcriptRevision: revision, defaults: defaults)
        XCTAssertEqual(BackgroundDictationState.phase(defaults: defaults), .ready)
        XCTAssertFalse(BackgroundDictationState.shouldStop(defaults: defaults))
        XCTAssertEqual(defaults.double(forKey: BackgroundDictationState.Keys.transcriptRevision), 200)
    }

    func testFailurePublishesMessageAndClearsStopRequest() {
        BackgroundDictationState.requestStop(defaults: defaults)
        BackgroundDictationState.fail("Microphone unavailable", defaults: defaults)

        XCTAssertEqual(BackgroundDictationState.phase(defaults: defaults), .failed)
        XCTAssertEqual(
            defaults.string(forKey: BackgroundDictationState.Keys.errorMessage),
            "Microphone unavailable"
        )
        XCTAssertFalse(BackgroundDictationState.shouldStop(defaults: defaults))
    }

    func testLiveActivityFailureMessageDoesNotBlameSettingsWhenAlreadyEnabled() {
        XCTAssertEqual(
            BackgroundDictationState.liveActivityFailureMessage(
                activitiesEnabled: true,
                requiresForegroundRetry: true
            ),
            "Open WhisperDict once, then run Start Dictation again."
        )
    }

    func testLiveActivityFailureMessageExplainsDisabledSetting() {
        XCTAssertEqual(
            BackgroundDictationState.liveActivityFailureMessage(
                activitiesEnabled: false,
                requiresForegroundRetry: false
            ),
            "Enable Live Activities for WhisperDict in Settings, then try again."
        )
    }

    func testClearFailureRemovesAStaleErrorWhenTheAppRelaunches() {
        BackgroundDictationState.fail("Old failure", defaults: defaults)

        BackgroundDictationState.clearFailure(defaults: defaults)

        XCTAssertEqual(BackgroundDictationState.phase(defaults: defaults), .idle)
        XCTAssertNil(defaults.string(forKey: BackgroundDictationState.Keys.errorMessage))
    }
}
