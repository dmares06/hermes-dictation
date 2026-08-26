import Foundation
import WhisperKit

actor DictationTranscriber {
    enum TranscriberError: LocalizedError {
        case modelMissing
        case noSpeech

        var errorDescription: String? {
            switch self {
            case .modelMissing: "Prepare a Whisper model before recording."
            case .noSpeech: "No speech was detected. Try speaking closer to the microphone."
            }
        }
    }

    private var whisperKit: WhisperKit?
    private var loadedModelPath: String?
    private var loadTask: Task<Void, Error>?

    /// Loads the model ahead of the transcription that will need it.
    ///
    /// Recording is the natural moment to call this: the load then overlaps
    /// with however long the user speaks, instead of landing between them
    /// finishing and seeing text. Failures are deliberately swallowed —
    /// `transcribe(audioURL:modelPath:)` reports them with real context.
    func prewarm(modelPath: String) async {
        guard FileManager.default.fileExists(atPath: modelPath) else { return }
        try? await ensureModel(at: modelPath)
    }

    func transcribe(audioURL: URL, modelPath: String) async throws -> String {
        guard FileManager.default.fileExists(atPath: modelPath) else {
            throw TranscriberError.modelMissing
        }
        try await ensureModel(at: modelPath)
        guard let whisperKit else { throw TranscriberError.modelMissing }
        let results = try await whisperKit.transcribe(audioPath: audioURL.path)
        let text = results.map(\.text).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw TranscriberError.noSpeech }
        return text
    }

    /// Ensures `whisperKit` holds the model at `modelPath`.
    ///
    /// A prewarm started at record time is usually still running when the
    /// transcription arrives, so an in-flight load is joined rather than
    /// started again — loading this model twice would cost more than the
    /// prewarm saves.
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
