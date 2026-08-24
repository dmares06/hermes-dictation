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

    func transcribe(audioURL: URL, modelPath: String) async throws -> String {
        guard FileManager.default.fileExists(atPath: modelPath) else {
            throw TranscriberError.modelMissing
        }
        if whisperKit == nil || loadedModelPath != modelPath {
            whisperKit = nil
            let config = WhisperKitConfig(modelFolder: modelPath, load: true, download: false)
            whisperKit = try await WhisperKit(config)
            loadedModelPath = modelPath
        }
        guard let whisperKit else { throw TranscriberError.modelMissing }
        let results = try await whisperKit.transcribe(audioPath: audioURL.path)
        let text = results.map(\.text).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw TranscriberError.noSpeech }
        return text
    }

    func releaseModel() {
        whisperKit = nil
        loadedModelPath = nil
    }
}
