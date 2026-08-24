import Foundation

public enum VoiceTurnDetection: Equatable, Sendable {
    case listening
    case finishTurn
    case idleTimeout
}

public struct VoiceTurnDetector: Sendable {
    public struct Configuration: Equatable, Sendable {
        public let speechThreshold: Float
        public let minimumSpeechDuration: TimeInterval
        public let endSilenceDuration: TimeInterval
        public let idleTimeout: TimeInterval

        public init(
            speechThreshold: Float = 0.08,
            minimumSpeechDuration: TimeInterval = 0.30,
            endSilenceDuration: TimeInterval = 1.10,
            idleTimeout: TimeInterval = 45
        ) {
            self.speechThreshold = max(0, min(speechThreshold, 1))
            self.minimumSpeechDuration = max(0, minimumSpeechDuration)
            self.endSilenceDuration = max(0.1, endSilenceDuration)
            self.idleTimeout = max(1, idleTimeout)
        }
    }

    private let configuration: Configuration
    private var turnStartedAt: TimeInterval?
    private var speechStartedAt: TimeInterval?
    private var lastSpeechAt: TimeInterval?
    private var hasFinished = false

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    public mutating func reset(at time: TimeInterval) {
        turnStartedAt = time
        speechStartedAt = nil
        lastSpeechAt = nil
        hasFinished = false
    }

    public mutating func observe(level: Float, at time: TimeInterval) -> VoiceTurnDetection {
        if turnStartedAt == nil {
            reset(at: time)
        }
        guard !hasFinished else { return .listening }

        if level >= configuration.speechThreshold {
            if speechStartedAt == nil {
                speechStartedAt = time
            }
            lastSpeechAt = time
            return .listening
        }

        if let speechStartedAt, let lastSpeechAt {
            let speechDuration = lastSpeechAt - speechStartedAt
            let silenceDuration = time - lastSpeechAt
            if speechDuration + 0.000_001 >= configuration.minimumSpeechDuration,
               silenceDuration + 0.000_001 >= configuration.endSilenceDuration {
                hasFinished = true
                return .finishTurn
            }
            if silenceDuration + 0.000_001 >= configuration.endSilenceDuration {
                self.speechStartedAt = nil
                self.lastSpeechAt = nil
            }
        }

        if let turnStartedAt, time - turnStartedAt >= configuration.idleTimeout {
            hasFinished = true
            return .idleTimeout
        }
        return .listening
    }
}
