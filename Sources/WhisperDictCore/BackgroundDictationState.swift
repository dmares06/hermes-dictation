import AppIntents
import Foundation

public enum BackgroundDictationPhase: String, Sendable {
    case idle
    case recording
    case transcribing
    case ready
    case failed
}

public enum DictationLaunchRoute {
    public static let recordingURL = URL(string: "whisperdict://record")!
    public static let stoppingURL = URL(string: "whisperdict://stop")!

    public static func isRecordingURL(_ url: URL) -> Bool {
        url.scheme == recordingURL.scheme && url.host == recordingURL.host
    }

    public static func isStoppingURL(_ url: URL) -> Bool {
        url.scheme == stoppingURL.scheme && url.host == stoppingURL.host
    }
}

public struct BackgroundDictationActivityContentState: Equatable, Sendable {
    public let phase: BackgroundDictationPhase
    public let startedAt: Date
}

public enum BackgroundDictationActivityContent {
    public static func recording(startedAt: Date) -> BackgroundDictationActivityContentState {
        .init(phase: .recording, startedAt: startedAt)
    }

    public static func transcribing(startedAt: Date) -> BackgroundDictationActivityContentState {
        .init(phase: .transcribing, startedAt: startedAt)
    }

    public static func ready(startedAt: Date) -> BackgroundDictationActivityContentState {
        .init(phase: .ready, startedAt: startedAt)
    }
}

public enum BackgroundDictationState {
    public static let appGroupID = "group.com.dmares06.whisperdict"
    public static let maximumRecordingDuration: TimeInterval = 5 * 60

    public enum Keys {
        public static let phase = "backgroundDictationPhase"
        public static let stopRequested = "backgroundDictationStopRequested"
        public static let startedAt = "backgroundDictationStartedAt"
        public static let errorMessage = "backgroundDictationError"
        public static let transcriptRevision = "backgroundDictationTranscriptRevision"
        public static let foregroundToggleRequest = "backgroundDictationForegroundToggleRequest"
        public static let heartbeat = "backgroundDictationHeartbeat"
        public static let intentStage = "backgroundDictationIntentStage"
    }

    public static let staleRecordingInterval: TimeInterval = 10
    public static let staleTranscribingInterval: TimeInterval = 5 * 60

    public static func phase(
        defaults: UserDefaults? = sharedDefaults,
        now: Date = Date()
    ) -> BackgroundDictationPhase {
        guard let rawValue = defaults?.string(forKey: Keys.phase) else { return .idle }
        let value = BackgroundDictationPhase(rawValue: rawValue) ?? .idle
        guard value == .recording || value == .transcribing else { return value }

        let heartbeat = defaults?.double(forKey: Keys.heartbeat) ?? 0
        let startedAt = defaults?.double(forKey: Keys.startedAt) ?? 0
        let lastActivity = heartbeat > 0 ? heartbeat : startedAt
        let staleInterval = value == .recording ? staleRecordingInterval : staleTranscribingInterval
        guard lastActivity > 0,
              now.timeIntervalSince1970 - lastActivity > staleInterval
        else { return value }

        fail("The previous dictation ended unexpectedly. Press the Action Button to start again.", defaults: defaults)
        return .failed
    }

    public static func begin(defaults: UserDefaults? = sharedDefaults, now: Date = Date()) {
        defaults?.set(false, forKey: Keys.stopRequested)
        defaults?.set(now.timeIntervalSince1970, forKey: Keys.startedAt)
        defaults?.set(now.timeIntervalSince1970, forKey: Keys.heartbeat)
        defaults?.removeObject(forKey: Keys.errorMessage)
        setPhase(.recording, defaults: defaults)
    }

    public static func requestStop(defaults: UserDefaults? = sharedDefaults) {
        defaults?.set(true, forKey: Keys.stopRequested)
    }

    public static func requestForegroundToggle(defaults: UserDefaults? = sharedDefaults) {
        defaults?.set(UUID().uuidString, forKey: Keys.foregroundToggleRequest)
    }

    public static func consumeForegroundToggleRequest(defaults: UserDefaults? = sharedDefaults) -> Bool {
        guard defaults?.string(forKey: Keys.foregroundToggleRequest) != nil else { return false }
        defaults?.removeObject(forKey: Keys.foregroundToggleRequest)
        return true
    }

    public static func shouldStop(defaults: UserDefaults? = sharedDefaults) -> Bool {
        defaults?.bool(forKey: Keys.stopRequested) == true
    }

    public static func heartbeat(defaults: UserDefaults? = sharedDefaults, now: Date = Date()) {
        defaults?.set(now.timeIntervalSince1970, forKey: Keys.heartbeat)
    }

    public static func markIntentStage(
        _ stage: String,
        defaults: UserDefaults? = sharedDefaults
    ) {
        defaults?.set(stage, forKey: Keys.intentStage)
    }

    public static func liveActivityFailureMessage(
        activitiesEnabled: Bool,
        requiresForegroundRetry: Bool
    ) -> String {
        guard activitiesEnabled else {
            return "Enable Live Activities for WhisperDict in Settings, then try again."
        }
        if requiresForegroundRetry {
            return "Open WhisperDict once, then run Start Dictation again."
        }
        return "WhisperDict couldn't start its recording indicator. Restart the iPhone, then try again."
    }

    public static func clearFailure(defaults: UserDefaults? = sharedDefaults) {
        guard defaults?.string(forKey: Keys.phase) == BackgroundDictationPhase.failed.rawValue else {
            return
        }
        defaults?.removeObject(forKey: Keys.errorMessage)
        defaults?.set(false, forKey: Keys.stopRequested)
        setPhase(.idle, defaults: defaults)
    }

    public static func recoverInterruptedSession(defaults: UserDefaults? = sharedDefaults) {
        switch phase(defaults: defaults) {
        case .recording, .transcribing, .failed:
            defaults?.removeObject(forKey: Keys.errorMessage)
            defaults?.set(false, forKey: Keys.stopRequested)
            setPhase(.idle, defaults: defaults)
        case .idle, .ready:
            break
        }
    }

    public static func isPublishableTranscript(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public static func setPhase(
        _ phase: BackgroundDictationPhase,
        defaults: UserDefaults? = sharedDefaults
    ) {
        defaults?.set(phase.rawValue, forKey: Keys.phase)
    }

    public static func finish(
        transcriptRevision: Date = Date(),
        defaults: UserDefaults? = sharedDefaults
    ) {
        defaults?.set(transcriptRevision.timeIntervalSince1970, forKey: Keys.transcriptRevision)
        defaults?.set(false, forKey: Keys.stopRequested)
        defaults?.removeObject(forKey: Keys.heartbeat)
        setPhase(.ready, defaults: defaults)
    }

    public static func fail(
        _ message: String,
        defaults: UserDefaults? = sharedDefaults
    ) {
        defaults?.set(message, forKey: Keys.errorMessage)
        defaults?.set(false, forKey: Keys.stopRequested)
        defaults?.removeObject(forKey: Keys.heartbeat)
        setPhase(.failed, defaults: defaults)
    }

    public static var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: appGroupID)
    }
}

public struct KeyboardTranscriptInsertionGate: Sendable {
    private var lastRevision: TimeInterval
    private var observedSessionStartedAt: TimeInterval = 0

    public init(currentRevision: TimeInterval) {
        lastRevision = currentRevision
    }

    public mutating func shouldInsert(
        phase: BackgroundDictationPhase,
        sessionStartedAt: TimeInterval,
        transcriptRevision: TimeInterval
    ) -> Bool {
        if phase == .recording || phase == .transcribing,
           sessionStartedAt > 0 {
            observedSessionStartedAt = sessionStartedAt
        }

        guard transcriptRevision > lastRevision else { return false }
        lastRevision = transcriptRevision
        guard phase == .ready,
              observedSessionStartedAt > 0,
              transcriptRevision >= observedSessionStartedAt
        else { return false }

        observedSessionStartedAt = 0
        return true
    }
}

@available(iOS 18.0, macOS 26.0, *)
public struct StopWhisperDictIntent: AppIntent {
    public static let title: LocalizedStringResource = "Stop WhisperDict"
    public static let description = IntentDescription("Stops the current private dictation.")

    public init() {}

    public func perform() async throws -> some IntentResult {
        BackgroundDictationState.requestStop()
        return .result()
    }
}
