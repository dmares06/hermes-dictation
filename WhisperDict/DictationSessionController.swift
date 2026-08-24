import ActivityKit
import AVFoundation
import Foundation
import Observation
import UIKit

@MainActor
@Observable
final class DictationSessionController {
    enum Phase: Equatable {
        case ready
        case recording
        case transcribing
        case failed(String)
    }

    private(set) var phase: Phase = .ready
    private(set) var transcript = ""
    private(set) var history: [SavedTranscript] = []
    private(set) var audioLevel: Float = 0
    private(set) var elapsedSeconds = 0
    private(set) var wasInterrupted = false
    private(set) var isKeyboardHandoffSession = false
    var showsMicrophoneSettings = false

    private let recorder: DictationAudioRecorder
    private let transcriber: DictationTranscriber
    private let store: TranscriptStore
    // Live access stays on the main actor; deinit may run from a nonisolated context.
    @ObservationIgnored
    nonisolated(unsafe) private var elapsedTask: Task<Void, Never>?
    @ObservationIgnored
    nonisolated(unsafe) private var stopRequestTask: Task<Void, Never>?
    @ObservationIgnored
    nonisolated(unsafe) private var memoryObserver: NSObjectProtocol?
    @ObservationIgnored
    private var backgroundActivity: Activity<WhisperDictActivityAttributes>?
    @ObservationIgnored
    private var backgroundActivityStartedAt: Date?

    init(
        recorder: DictationAudioRecorder = DictationAudioRecorder(),
        transcriber: DictationTranscriber = DictationTranscriber(),
        store: TranscriptStore = TranscriptStore()
    ) {
        self.recorder = recorder
        self.transcriber = transcriber
        self.store = store
        transcript = store.latest?.text ?? ""
        history = store.history

        recorder.onLevel = { [weak self] level in
            Task { @MainActor in self?.audioLevel = level }
        }
        recorder.onInterruption = { [weak self] in
            Task { @MainActor in await self?.stopAndTranscribe(interrupted: true) }
        }
        memoryObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.handleMemoryPressure() }
        }
    }

    deinit {
        elapsedTask?.cancel()
        stopRequestTask?.cancel()
        if let memoryObserver {
            NotificationCenter.default.removeObserver(memoryObserver)
        }
    }

    var isRecording: Bool { phase == .recording }
    var isBusy: Bool { phase == .transcribing }

    var statusText: String {
        switch phase {
        case .ready: transcript.isEmpty ? "Ready when you are" : "Ready for another thought"
        case .recording: "Listening…"
        case .transcribing: "Transcribing on this iPhone…"
        case .failed(let message): message
        }
    }

    func toggleRecording(settings: SharedState) async {
        if isRecording {
            await stopAndTranscribe(settings: settings)
        } else {
            await startRecording(settings: settings)
        }
    }

    func startFromKeyboard(settings: SharedState) async {
        guard !isRecording, !isBusy else { return }
        await startRecording(settings: settings, keyboardHandoff: true)
    }

    func toggleFromShortcut(settings: SharedState) async {
        if isRecording {
            await stopAndTranscribe(settings: settings)
        } else {
            await startFromKeyboard(settings: settings)
        }
    }

    func stopFromKeyboard(settings: SharedState) async {
        guard isRecording else { return }
        await stopAndTranscribe(settings: settings)
    }

    func stopIfNeeded(settings: SharedState) async {
        guard isRecording else { return }
        await stopAndTranscribe(settings: settings, interrupted: true)
    }

    func copyTranscript(_ value: String? = nil) {
        let value = value ?? transcript
        guard !value.isEmpty else { return }
        UIPasteboard.general.string = value
    }

    func clearHistory() {
        store.clear()
        transcript = ""
        history = []
    }

    func dismissError() {
        if case .failed = phase { phase = .ready }
    }

    func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private func startRecording(settings: SharedState, keyboardHandoff: Bool = false) async {
        guard !isBusy else { return }
        let defaults = UserDefaults(suiteName: SharedState.appGroupID)
        guard let modelPath = settings.modelFolderPath,
              FileManager.default.fileExists(atPath: modelPath)
        else {
            phase = .failed("Prepare the speech model below before recording.")
            return
        }
        let preparedModel = defaults?.string(forKey: "preparedModelSize")
        guard preparedModel == settings.modelSize.rawValue || modelPath.localizedCaseInsensitiveContains(settings.modelSize.rawValue) else {
            phase = .failed("Prepare the selected \(settings.modelSize.title) model before recording.")
            return
        }

        let permission = await microphonePermission()
        guard permission else {
            phase = .failed("Microphone access is off. Enable it in Settings to dictate.")
            showsMicrophoneSettings = true
            return
        }

        do {
            try recorder.start()
            let startedAt = Date()
            isKeyboardHandoffSession = keyboardHandoff
            wasInterrupted = false
            elapsedSeconds = 0
            audioLevel = 0
            phase = .recording
            startElapsedTimer()
            if keyboardHandoff {
                BackgroundDictationState.begin(now: startedAt)
                startBackgroundActivity(startedAt: startedAt)
                startStopRequestMonitor(settings: settings, startedAt: startedAt)
            }
        } catch {
            if keyboardHandoff {
                BackgroundDictationState.fail(error.localizedDescription)
            }
            isKeyboardHandoffSession = false
            phase = .failed(error.localizedDescription)
        }
    }

    private func stopAndTranscribe(settings: SharedState? = nil, interrupted: Bool = false) async {
        guard let audioURL = recorder.stop() else {
            if isRecording {
                let message = "The recording was empty. Please try again."
                if isKeyboardHandoffSession {
                    BackgroundDictationState.fail(message)
                    await endBackgroundActivity(finalState: nil, dismissalPolicy: .immediate)
                }
                isKeyboardHandoffSession = false
                phase = .failed(message)
            }
            return
        }
        elapsedTask?.cancel()
        elapsedTask = nil
        stopRequestTask?.cancel()
        stopRequestTask = nil
        wasInterrupted = interrupted
        phase = .transcribing
        if isKeyboardHandoffSession {
            BackgroundDictationState.setPhase(.transcribing)
            await updateBackgroundActivity(
                BackgroundDictationActivityContent.transcribing(startedAt: backgroundActivityStartedAt ?? Date())
            )
        }

        defer { try? FileManager.default.removeItem(at: audioURL) }
        let defaults = UserDefaults(suiteName: SharedState.appGroupID)
        let modelPath = settings?.modelFolderPath ?? defaults?.string(forKey: "modelFolderPath")
        guard let modelPath else {
            if isKeyboardHandoffSession {
                BackgroundDictationState.fail("The speech model is missing. Prepare it again in WhisperDict.")
                await endBackgroundActivity(finalState: nil, dismissalPolicy: .immediate)
            }
            isKeyboardHandoffSession = false
            phase = .failed("The speech model is missing. Prepare it again below.")
            return
        }

        do {
            let rawText = try await transcriber.transcribe(audioURL: audioURL, modelPath: modelPath)
            let options = TranscriptCleanupOptions(
                removeFillers: settings?.removeFillers ?? defaults?.object(forKey: "removeFillers") as? Bool ?? true,
                autoPunctuate: settings?.autoPunctuate ?? defaults?.object(forKey: "autoPunctuate") as? Bool ?? true,
                autoCapitalize: settings?.autoCapitalize ?? defaults?.object(forKey: "autoCapitalize") as? Bool ?? true
            )
            let cleaned = TranscriptCleaner.clean(rawText, options: options)
            guard BackgroundDictationState.isPublishableTranscript(cleaned) else {
                let message = "No speech was detected. Try speaking closer to the microphone."
                if isKeyboardHandoffSession {
                    BackgroundDictationState.fail(message)
                    await endBackgroundActivity(finalState: nil, dismissalPolicy: .immediate)
                }
                isKeyboardHandoffSession = false
                phase = .failed(message)
                return
            }
            try store.save(cleaned)
            defaults?.set(cleaned, forKey: "pendingTranscription")
            defaults?.set(Date().timeIntervalSince1970, forKey: "pendingTranscriptionDate")
            UIPasteboard.general.string = cleaned
            transcript = cleaned
            history = store.history
            if isKeyboardHandoffSession {
                BackgroundDictationState.finish()
                let startedAt = backgroundActivityStartedAt ?? Date()
                await endBackgroundActivity(
                    finalState: BackgroundDictationActivityContent.ready(startedAt: startedAt),
                    dismissalPolicy: .after(Date().addingTimeInterval(8))
                )
            }
            isKeyboardHandoffSession = false
            phase = .ready
        } catch {
            if isKeyboardHandoffSession {
                BackgroundDictationState.fail(error.localizedDescription)
                await endBackgroundActivity(finalState: nil, dismissalPolicy: .immediate)
            }
            isKeyboardHandoffSession = false
            phase = .failed(error.localizedDescription)
        }
    }

    private func microphonePermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return true
        case .denied: return false
        case .undetermined:
            return await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        @unknown default: return false
        }
    }

    private func startElapsedTimer() {
        elapsedTask?.cancel()
        elapsedTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self, self.isRecording else { return }
                self.elapsedSeconds += 1
            }
        }
    }

    private func startStopRequestMonitor(settings: SharedState, startedAt: Date) {
        stopRequestTask?.cancel()
        stopRequestTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled, let self, self.isRecording else { return }
                let reachedDurationLimit = Date().timeIntervalSince(startedAt)
                    >= BackgroundDictationState.maximumRecordingDuration
                if BackgroundDictationState.shouldStop() || reachedDurationLimit {
                    Task { @MainActor [weak self] in
                        await self?.stopAndTranscribe(settings: settings)
                    }
                    return
                }
            }
        }
    }

    private func startBackgroundActivity(startedAt: Date) {
        let state = BackgroundDictationActivityContent.recording(startedAt: startedAt)
        do {
            let content = ActivityContent(
                state: activityState(from: state),
                staleDate: startedAt.addingTimeInterval(5 * 60)
            )
            if #available(iOS 18.0, *) {
                backgroundActivity = try Activity.request(
                    attributes: WhisperDictActivityAttributes(),
                    content: content,
                    pushType: nil,
                    style: .standard
                )
            } else {
                backgroundActivity = try Activity.request(
                    attributes: WhisperDictActivityAttributes(),
                    content: content,
                    pushType: nil
                )
            }
            backgroundActivityStartedAt = startedAt
        } catch {
            NSLog("WhisperDict Live Activity could not start: \(error.localizedDescription)")
        }
    }

    private func updateBackgroundActivity(_ state: BackgroundDictationActivityContentState) async {
        guard let backgroundActivity else { return }
        await backgroundActivity.update(
            ActivityContent(
                state: activityState(from: state),
                staleDate: Date().addingTimeInterval(60)
            )
        )
    }

    private func endBackgroundActivity(
        finalState: BackgroundDictationActivityContentState?,
        dismissalPolicy: ActivityUIDismissalPolicy
    ) async {
        guard let backgroundActivity else { return }
        let content = finalState.map {
            ActivityContent(state: activityState(from: $0), staleDate: nil)
        }
        await backgroundActivity.end(content, dismissalPolicy: dismissalPolicy)
        self.backgroundActivity = nil
        backgroundActivityStartedAt = nil
    }

    private func activityState(
        from state: BackgroundDictationActivityContentState
    ) -> WhisperDictActivityAttributes.ContentState {
        .init(phase: state.phase, startedAt: state.startedAt)
    }

    private func handleMemoryPressure() async {
        guard !isRecording, !isBusy else { return }
        await transcriber.releaseModel()
    }
}
