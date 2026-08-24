#if canImport(ActivityKit) && os(iOS)
import ActivityKit
import Foundation

public struct WhisperDictActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        public let phase: BackgroundDictationPhase
        public let startedAt: Date

        public init(phase: BackgroundDictationPhase, startedAt: Date) {
            self.phase = phase
            self.startedAt = startedAt
        }
    }

    public init() {}
}

extension BackgroundDictationPhase: Codable {}
#endif
