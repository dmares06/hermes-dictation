import Foundation
import Observation
import WhisperKit

@MainActor
@Observable
final class ModelDownloadService {
    var isPrepared = false
    var isPreparing = false
    var progress = 0.0
    var errorMessage: String?

    init() {
        refresh()
    }

    func refresh(for model: ModelSize? = nil) {
        guard let path = UserDefaults(suiteName: SharedState.appGroupID)?.string(forKey: "modelFolderPath") else {
            isPrepared = false
            return
        }
        let preparedModel = UserDefaults(suiteName: SharedState.appGroupID)?.string(forKey: "preparedModelSize")
        let matchesSelection = model.map { preparedModel == $0.rawValue || path.localizedCaseInsensitiveContains($0.rawValue) } ?? true
        isPrepared = matchesSelection && FileManager.default.fileExists(atPath: path)
    }

    func prepare(model: ModelSize) async {
        isPreparing = true
        errorMessage = nil
        progress = 0
        do {
            let groupURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: SharedState.appGroupID)
                ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            let variant = "openai_whisper-\(model.rawValue)"
            let folder = try await WhisperKit.download(
                variant: variant,
                downloadBase: groupURL,
                useBackgroundSession: true,
                progressCallback: { [weak self] value in
                    Task { @MainActor in self?.progress = value.fractionCompleted }
                }
            )
            UserDefaults(suiteName: SharedState.appGroupID)?.set(folder.path, forKey: "modelFolderPath")
            UserDefaults(suiteName: SharedState.appGroupID)?.set(true, forKey: "modelDownloaded")
            UserDefaults(suiteName: SharedState.appGroupID)?.set(model.rawValue, forKey: "preparedModelSize")
        } catch {
            errorMessage = error.localizedDescription
            isPreparing = false
            return
        }
        isPrepared = true
        isPreparing = false
    }
}
