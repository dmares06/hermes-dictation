import Foundation
import WhisperKit

/// Records how long the last transcription actually took, and where the time
/// went.
///
/// Latency work on device is otherwise guesswork: the pieces that dominate
/// (model load, mel extraction, the encoder pass, the decode loop) are
/// invisible from the outside and trade against each other. Keeping the last
/// breakdown in the app group means it can be read back off the phone after a
/// real dictation instead of inferred from how it felt.
enum DictationLatencyLog {
    static let key = "lastDictationLatency"

    static func record(elapsed: TimeInterval, audioSeconds: Double, timings: TranscriptionTimings) {
        let summary: [String: Any] = [
            "at": Date().timeIntervalSince1970,
            "totalSeconds": rounded(elapsed),
            "audioSeconds": rounded(audioSeconds),
            // Zero once the model is resident: anything else means a prewarm
            // was missed and the user waited for a load.
            "modelLoadingSeconds": rounded(timings.modelLoading),
            "logmelSeconds": rounded(timings.logmels),
            "encodingSeconds": rounded(timings.encoding),
            "decodingLoopSeconds": rounded(timings.decodingLoop),
            "decodingFallbackSeconds": rounded(timings.decodingFallback),
            "decodingLoops": timings.totalDecodingLoops,
            "fallbacks": timings.totalDecodingFallbacks,
        ]
        UserDefaults(suiteName: SharedState.appGroupID)?.set(summary, forKey: key)
        NSLog(
            "WhisperDict latency: %.2fs for %.1fs of audio (load %.2f, mel %.2f, encode %.2f, decode %.2f, fallbacks %.0f)",
            elapsed,
            audioSeconds,
            timings.modelLoading,
            timings.logmels,
            timings.encoding,
            timings.decodingLoop,
            timings.totalDecodingFallbacks
        )
    }

    private static func rounded(_ value: TimeInterval) -> Double {
        (value * 1000).rounded() / 1000
    }
}
