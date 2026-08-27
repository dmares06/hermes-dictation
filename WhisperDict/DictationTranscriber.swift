import Foundation
import WhisperKit

actor DictationTranscriber {
    enum TranscriberError: LocalizedError {
        case modelMissing
        case noSpeech

        var errorDescription: String? {
            switch self {
            case .modelMissing: "Prepare a speech model before recording."
            case .noSpeech: "No speech was detected. Try speaking closer to the microphone."
            }
        }
    }

    /// Decoding tuned for dictation rather than for transcribing media.
    ///
    /// - `language` is pinned so no window is ever spent identifying it.
    /// - `withoutTimestamps` drops the `<|0.00|>` markers Whisper otherwise
    ///   emits around every segment. Nothing here uses them, and they are a
    ///   large share of the tokens decoded for a short utterance.
    /// - `temperatureFallbackCount` is the worst case, not the common one: a
    ///   decode that trips the compression or log-prob threshold is retried
    ///   at a higher temperature, and the stock five retries mean a noisy
    ///   clip can cost six full decodes. One retry keeps the recovery and
    ///   bounds the wait.
    /// - `chunkingStrategy` only engages past 30 s of audio, where it splits
    ///   on silence and decodes the pieces concurrently.
    private static let dictationOptions = DecodingOptions(
        language: "en",
        temperatureFallbackCount: 1,
        detectLanguage: false,
        skipSpecialTokens: true,
        withoutTimestamps: true,
        chunkingStrategy: .vad
    )

    private var whisperKit: WhisperKit?
    private var loadedModelPath: String?
    private var loadTask: Task<Void, Error>?

    /// Loads the model ahead of the transcription that will need it.
    ///
    /// The best moment is whenever the app can tell a dictation is plausible
    /// — the listening window opening, or the app coming forward — because
    /// the load then costs nothing the user can perceive. Calling it again at
    /// record time is harmless: an in-flight load is joined, not restarted.
    /// Failures are deliberately swallowed; `transcribe` reports them with
    /// real context.
    func prewarm(modelPath: String) async {
        guard FileManager.default.fileExists(atPath: modelPath) else { return }
        try? await ensureModel(at: modelPath)
    }

    /// - Parameter samples: 16 kHz mono audio, as captured.
    func transcribe(samples: [Float], modelPath: String) async throws -> String {
        guard FileManager.default.fileExists(atPath: modelPath) else {
            throw TranscriberError.modelMissing
        }
        try await ensureModel(at: modelPath)
        guard let whisperKit else { throw TranscriberError.modelMissing }

        let startedAt = Date()
        let results = try await whisperKit.transcribe(
            audioArray: samples,
            decodeOptions: Self.dictationOptions
        )
        DictationLatencyLog.record(
            elapsed: Date().timeIntervalSince(startedAt),
            audioSeconds: Double(samples.count) / 16_000,
            timings: whisperKit.currentTimings
        )

        let text = results.map(\.text).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw TranscriberError.noSpeech }
        return text
    }

    /// Ensures `whisperKit` holds the model at `modelPath`.
    ///
    /// A prewarm is usually still running when the transcription arrives, so
    /// an in-flight load is joined rather than started again — loading this
    /// model twice would cost more than the prewarm saves.
    private func ensureModel(at modelPath: String) async throws {
        if whisperKit != nil, loadedModelPath == modelPath { return }
        if let loadTask, loadedModelPath == modelPath {
            try await loadTask.value
            return
        }

        loadTask?.cancel()
        whisperKit = nil
        loadedModelPath = modelPath

        // Created in actor context, so the load stays isolated to this actor
        // and the model never crosses an isolation boundary.
        let task = Task {
            let config = WhisperKitConfig(modelFolder: modelPath, load: true, download: false)
            self.whisperKit = try await WhisperKit(config)
        }
        loadTask = task

        do {
            try await task.value
            loadTask = nil
        } catch {
            loadTask = nil
            loadedModelPath = nil
            throw error
        }
    }

    func releaseModel() {
        loadTask?.cancel()
        loadTask = nil
        whisperKit = nil
        loadedModelPath = nil
    }
}
