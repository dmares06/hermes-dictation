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

    func testShortcutStartsRecordingThroughTheForegroundAppRoute() {
        XCTAssertEqual(DictationLaunchRoute.recordingURL.scheme, "whisperdict")
        XCTAssertEqual(DictationLaunchRoute.recordingURL.host, "record")
        XCTAssertTrue(DictationLaunchRoute.isRecordingURL(DictationLaunchRoute.recordingURL))
    }

    func testShortcutForegroundToggleRequestIsConsumedExactlyOnce() {
        BackgroundDictationState.requestForegroundToggle(defaults: defaults)

        XCTAssertTrue(BackgroundDictationState.consumeForegroundToggleRequest(defaults: defaults))
        XCTAssertFalse(BackgroundDictationState.consumeForegroundToggleRequest(defaults: defaults))
    }

    func testShortcutStopsAnActiveRecordingThroughTheForegroundAppRoute() {
        XCTAssertEqual(DictationLaunchRoute.stoppingURL.scheme, "whisperdict")
        XCTAssertEqual(DictationLaunchRoute.stoppingURL.host, "stop")
        XCTAssertTrue(DictationLaunchRoute.isStoppingURL(DictationLaunchRoute.stoppingURL))
        XCTAssertFalse(DictationLaunchRoute.isRecordingURL(DictationLaunchRoute.stoppingURL))
    }

    func testUnrelatedDeepLinksDoNotStartRecording() throws {
        let agentURL = try XCTUnwrap(URL(string: "whisperdict://agent"))

        XCTAssertFalse(DictationLaunchRoute.isRecordingURL(agentURL))
    }

    func testForegroundRecordingPublishesLiveActivityPhases() {
        let startedAt = Date(timeIntervalSince1970: 100)

        XCTAssertEqual(
            BackgroundDictationActivityContent.recording(startedAt: startedAt).phase,
            .recording
        )
        XCTAssertEqual(
            BackgroundDictationActivityContent.transcribing(startedAt: startedAt).phase,
            .transcribing
        )
        XCTAssertEqual(
            BackgroundDictationActivityContent.ready(startedAt: startedAt).phase,
            .ready
        )
    }

    func testShortcutRecordingRetainsTheFiveMinuteSafetyLimit() {
        XCTAssertEqual(BackgroundDictationState.maximumRecordingDuration, 5 * 60)
    }

    func testAppLaunchRecoversAnInterruptedRecording() {
        BackgroundDictationState.begin(defaults: defaults)

        BackgroundDictationState.recoverInterruptedSession(defaults: defaults)

        XCTAssertEqual(BackgroundDictationState.phase(defaults: defaults), .idle)
        XCTAssertFalse(BackgroundDictationState.shouldStop(defaults: defaults))
    }

    func testOnlyNonemptyTranscriptsCanBePublishedToTheKeyboard() {
        XCTAssertFalse(BackgroundDictationState.isPublishableTranscript(""))
        XCTAssertFalse(BackgroundDictationState.isPublishableTranscript("  \n "))
        XCTAssertTrue(BackgroundDictationState.isPublishableTranscript("Send this"))
    }
}

final class KeyboardHandoffGuidanceTests: XCTestCase {
    func testIdleKeyboardUsesActionButtonInsteadOfAProhibitedURLLaunch() {
        XCTAssertEqual(
            KeyboardHandoffGuidance.recorderAction(for: .idle),
            .showActionButtonGuidance
        )
        XCTAssertEqual(
            KeyboardHandoffGuidance.recorderAction(for: .ready),
            .showActionButtonGuidance
        )
    }

    func testActiveKeyboardRecordingCanStillRequestStop() {
        XCTAssertEqual(
            KeyboardHandoffGuidance.recorderAction(for: .recording),
            .requestStop
        )
    }

    func testIdleRecordControlNamesTheSupportedActionButtonEntryPoint() {
        XCTAssertEqual(
            KeyboardHandoffGuidance.recorderButtonTitle(for: .idle),
            "Action Button"
        )
        XCTAssertEqual(
            KeyboardHandoffGuidance.recorderButtonTitle(for: .recording),
            "Stop"
        )
    }

    func testMissingFullAccessExplainsWhyInsertionCannotWork() {
        XCTAssertEqual(
            KeyboardHandoffGuidance.idleMessage(hasFullAccess: false),
            "Turn on Full Access for WhisperDict in Settings to insert recordings here"
        )
    }

    func testReadyKeyboardExplainsTheActionButtonFlow() {
        XCTAssertEqual(
            KeyboardHandoffGuidance.idleMessage(hasFullAccess: true),
            "Press your iPhone Action Button to record and insert"
        )
    }
}
