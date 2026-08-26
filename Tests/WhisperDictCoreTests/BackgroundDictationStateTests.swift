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
        XCTAssertEqual(
            BackgroundDictationState.phase(
                defaults: defaults,
                now: Date(timeIntervalSince1970: 100)
            ),
            .recording
        )
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

    func testStaleRecordingIsRecoveredInsteadOfRemainingStuck() {
        BackgroundDictationState.begin(
            defaults: defaults,
            now: Date(timeIntervalSince1970: 100)
        )

        XCTAssertEqual(
            BackgroundDictationState.phase(
                defaults: defaults,
                now: Date(timeIntervalSince1970: 111)
            ),
            .failed
        )
        XCTAssertEqual(
            defaults.string(forKey: BackgroundDictationState.Keys.errorMessage),
            "The previous dictation ended unexpectedly. Press the Action Button to start again."
        )
    }

    func testHeartbeatKeepsAnActiveRecordingAlive() {
        BackgroundDictationState.begin(
            defaults: defaults,
            now: Date(timeIntervalSince1970: 100)
        )
        BackgroundDictationState.heartbeat(
            defaults: defaults,
            now: Date(timeIntervalSince1970: 109)
        )

        XCTAssertEqual(
            BackgroundDictationState.phase(
                defaults: defaults,
                now: Date(timeIntervalSince1970: 111)
            ),
            .recording
        )
    }

    func testIntentStageIsPersistedForActionButtonDiagnostics() {
        BackgroundDictationState.markIntentStage("invoked", defaults: defaults)

        XCTAssertEqual(
            defaults.string(forKey: BackgroundDictationState.Keys.intentStage),
            "invoked"
        )
    }

    func testStaleTranscriptionIsRecovered() {
        BackgroundDictationState.begin(
            defaults: defaults,
            now: Date(timeIntervalSince1970: 100)
        )
        BackgroundDictationState.setPhase(.transcribing, defaults: defaults)

        XCTAssertEqual(
            BackgroundDictationState.phase(
                defaults: defaults,
                now: Date(timeIntervalSince1970: 401)
            ),
            .failed
        )
    }

    func testOldTranscriptNeverInsertsWithoutAnObservedRecording() {
        var gate = KeyboardTranscriptInsertionGate(currentRevision: 100)

        XCTAssertFalse(
            gate.shouldInsert(phase: .ready, sessionStartedAt: 0, transcriptRevision: 200)
        )
    }

    func testObservedRecordingInsertsItsResultExactlyOnce() {
        var gate = KeyboardTranscriptInsertionGate(currentRevision: 100)

        XCTAssertFalse(
            gate.shouldInsert(phase: .recording, sessionStartedAt: 150, transcriptRevision: 100)
        )
        XCTAssertFalse(
            gate.shouldInsert(phase: .transcribing, sessionStartedAt: 150, transcriptRevision: 100)
        )
        XCTAssertTrue(
            gate.shouldInsert(phase: .ready, sessionStartedAt: 150, transcriptRevision: 200)
        )
        XCTAssertFalse(
            gate.shouldInsert(phase: .ready, sessionStartedAt: 150, transcriptRevision: 200)
        )
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
            "Press and hold the physical Action Button. You stay in this app."
        )
    }

    func testIdleKeyboardPointsAtTheActionButton() {
        XCTAssertEqual(
            KeyboardHandoffGuidance.recorderButtonTitle(for: .idle),
            "Action Button"
        )
        XCTAssertEqual(
            KeyboardHandoffGuidance.recorderButtonTitle(for: .ready),
            "Action Button"
        )
        XCTAssertEqual(
            KeyboardHandoffGuidance.recorderButtonTitle(for: .recording),
            "Stop"
        )
        XCTAssertEqual(
            KeyboardHandoffGuidance.recorderButtonTitle(for: .transcribing),
            "Working"
        )
    }

    func testKeyboardExplainsTheActionButtonHandoff() {
        XCTAssertEqual(
            KeyboardHandoffGuidance.micButtonMessage(hasFullAccess: true),
            "Press your iPhone Action Button to open WhisperDict and record."
        )
        XCTAssertEqual(
            KeyboardHandoffGuidance.micButtonMessage(hasFullAccess: false),
            "Allow Full Access first so Hermes can return the transcript to this keyboard."
        )
    }
}
