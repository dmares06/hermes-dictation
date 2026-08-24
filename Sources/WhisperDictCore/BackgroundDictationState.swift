import AppIntents
import Foundation

public enum BackgroundDictationPhase: String, Sendable {
    case idle
    case recording
    case transcribing
    case ready
    case failed
}

public enum BackgroundDictationState {
    public static let appGroupID = "group.com.dmares06.whisperdict"

    public enum Keys {
        public static let phase = "backgroundDictationPhase"
        public static let stopRequested = "backgroundDictationStopRequested"
        public static let startedAt = "backgroundDictationStartedAt"
        public static let errorMessage = "backgroundDictationError"
        public static let transcriptRevision = "backgroundDictationTranscriptRevision"
    }

    public static func phase(defaults: UserDefaults? = sharedDefaults) -> BackgroundDictationPhase {
        guard let rawValue = defaults?.string(forKey: Keys.phase) else { return .idle }
        return BackgroundDictationPhase(rawValue: rawValue) ?? .idle
    }

    public static func begin(defaults: UserDefaults? = sharedDefaults, now: Date = Date()) {
        defaults?.set(false, forKey: Keys.stopRequested)
        defaults?.set(now.timeIntervalSince1970, forKey: Keys.startedAt)
        defaults?.removeObject(forKey: Keys.errorMessage)
        setPhase(.recording, defaults: defaults)
    }

    public static func requestStop(defaults: UserDefaults? = sharedDefaults) {
        defaults?.set(true, forKey: Keys.stopRequested)
    }

    public static func shouldStop(defaults: UserDefaults? = sharedDefaults) -> Bool {
        defaults?.bool(forKey: Keys.stopRequested) == true
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
        setPhase(.ready, defaults: defaults)
    }

    public static func fail(
        _ message: String,
        defaults: UserDefaults? = sharedDefaults
    ) {
        defaults?.set(message, forKey: Keys.errorMessage)
        defaults?.set(false, forKey: Keys.stopRequested)
        setPhase(.failed, defaults: defaults)
    }

    public static var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: appGroupID)
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
