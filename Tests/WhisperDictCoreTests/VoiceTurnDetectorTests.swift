import XCTest
@testable import WhisperDictCore

final class VoiceTurnDetectorTests: XCTestCase {
    private let configuration = VoiceTurnDetector.Configuration(
        speechThreshold: 0.10,
        minimumSpeechDuration: 0.30,
        endSilenceDuration: 1.0,
        idleTimeout: 5.0
    )

    func testSilenceBeforeSpeechDoesNotFinishATurn() {
        var detector = VoiceTurnDetector(configuration: configuration)
        detector.reset(at: 10)

        XCTAssertEqual(detector.observe(level: 0.02, at: 11), .listening)
        XCTAssertEqual(detector.observe(level: 0.02, at: 12), .listening)
    }

    func testSustainedSpeechThenSilenceFinishesExactlyOnce() {
        var detector = VoiceTurnDetector(configuration: configuration)
        detector.reset(at: 0)

        XCTAssertEqual(detector.observe(level: 0.20, at: 0.5), .listening)
        XCTAssertEqual(detector.observe(level: 0.25, at: 0.9), .listening)
        XCTAssertEqual(detector.observe(level: 0.02, at: 1.5), .listening)
        XCTAssertEqual(detector.observe(level: 0.02, at: 1.9), .finishTurn)
        XCTAssertEqual(detector.observe(level: 0.02, at: 2.5), .listening)
    }

    func testBriefNoiseDoesNotCountAsACompleteUtterance() {
        var detector = VoiceTurnDetector(configuration: configuration)
        detector.reset(at: 0)

        XCTAssertEqual(detector.observe(level: 0.20, at: 0.5), .listening)
        XCTAssertEqual(detector.observe(level: 0.02, at: 2.0), .listening)
    }

    func testNewSpeechExtendsTheEndOfTurnWindow() {
        var detector = VoiceTurnDetector(configuration: configuration)
        detector.reset(at: 0)

        _ = detector.observe(level: 0.20, at: 0.5)
        _ = detector.observe(level: 0.20, at: 0.9)
        XCTAssertEqual(detector.observe(level: 0.02, at: 1.6), .listening)
        XCTAssertEqual(detector.observe(level: 0.20, at: 1.7), .listening)
        XCTAssertEqual(detector.observe(level: 0.02, at: 2.4), .listening)
        XCTAssertEqual(detector.observe(level: 0.02, at: 2.8), .finishTurn)
    }

    func testIdleTimeoutEndsAConversationWithoutTranscription() {
        var detector = VoiceTurnDetector(configuration: configuration)
        detector.reset(at: 20)

        XCTAssertEqual(detector.observe(level: 0.01, at: 24.9), .listening)
        XCTAssertEqual(detector.observe(level: 0.01, at: 25.0), .idleTimeout)
    }

    func testResetAllowsTheNextTurnToComplete() {
        var detector = VoiceTurnDetector(configuration: configuration)
        detector.reset(at: 0)
        _ = detector.observe(level: 0.20, at: 0.2)
        _ = detector.observe(level: 0.20, at: 0.6)
        XCTAssertEqual(detector.observe(level: 0.01, at: 1.6), .finishTurn)

        detector.reset(at: 10)
        _ = detector.observe(level: 0.20, at: 10.2)
        _ = detector.observe(level: 0.20, at: 10.6)
        XCTAssertEqual(detector.observe(level: 0.01, at: 11.6), .finishTurn)
    }

    func testDefaultDetectorAllowsANaturalPauseBeforeFinishing() {
        var detector = VoiceTurnDetector()
        detector.reset(at: 0)

        XCTAssertEqual(detector.observe(level: 0.55, at: 0.2), .listening)
        XCTAssertEqual(detector.observe(level: 0.50, at: 0.6), .listening)
        XCTAssertEqual(detector.observe(level: 0.12, at: 1.0), .listening)
        XCTAssertEqual(detector.observe(level: 0.02, at: 2.5), .listening)
        XCTAssertEqual(detector.observe(level: 0.02, at: 3.25), .finishTurn)
    }

    func testDefaultDetectorDoesNotCutOffALongerSpokenTurn() {
        var detector = VoiceTurnDetector()
        detector.reset(at: 0)

        XCTAssertEqual(detector.observe(level: 0.50, at: 0.2), .listening)
        XCTAssertEqual(detector.observe(level: 0.50, at: 0.8), .listening)
        XCTAssertEqual(detector.observe(level: 0.50, at: 30), .listening)
        XCTAssertEqual(detector.observe(level: 0.50, at: 90), .listening)
        XCTAssertEqual(detector.observe(level: 0.50, at: 120), .finishTurn)
    }

    func testMaximumTurnDurationPreventsEndlessListeningInConstantNoise() {
        var detector = VoiceTurnDetector(
            configuration: .init(
                speechThreshold: 0.10,
                minimumSpeechDuration: 0.30,
                endSilenceDuration: 1.0,
                idleTimeout: 45,
                maximumTurnDuration: 3.0
            )
        )
        detector.reset(at: 0)

        XCTAssertEqual(detector.observe(level: 0.30, at: 0.2), .listening)
        XCTAssertEqual(detector.observe(level: 0.30, at: 0.6), .listening)
        XCTAssertEqual(detector.observe(level: 0.30, at: 2.9), .listening)
        XCTAssertEqual(detector.observe(level: 0.30, at: 3.0), .finishTurn)
    }
}
