import ActivityKit
import AppIntents
import AVFoundation
import Foundation
import UIKit

@available(iOS 18.0, *)
struct StartWhisperDictIntent: AudioRecordingIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "Start WhisperDict"
    static let description = IntentDescription("Toggles private on-device dictation without leaving the current app.")

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        if BackgroundDictationState.phase() == .recording {
            BackgroundDictationState.requestStop()
            return .result(value: "", dialog: "Stopping WhisperDict")
        }

        let result = await BackgroundDictationRunner.run()
        return .result(value: result.transcript, dialog: IntentDialog(stringLiteral: result.message))
    }
}

@available(iOS 18.0, *)
@MainActor
private enum BackgroundDictationRunner {
    struct Result {
        let transcript: String
        let message: String
    }

    static func run() async -> Result {
        let defaults = BackgroundDictationState.sharedDefaults
        guard AVAudioApplication.shared.recordPermission == .granted else {
            let message = "Open WhisperDict once and allow microphone access."
            BackgroundDictationState.fail(message, defaults: defaults)
            return Result(transcript: "", message: message)
        }
        guard let modelPath = defaults?.string(forKey: "modelFolderPath"),
              FileManager.default.fileExists(atPath: modelPath)
        else {
            let message = "Prepare the speech model in WhisperDict first."
            BackgroundDictationState.fail(message, defaults: defaults)
            return Result(transcript: "", message: message)
        }

        let startedAt = Date()
        let activity: Activity<WhisperDictActivityAttributes>
        do {
            activity = try Activity.request(
                attributes: WhisperDictActivityAttributes(),
                content: ActivityContent(
                    state: .init(phase: .recording, startedAt: startedAt),
                    staleDate: startedAt.addingTimeInterval(5 * 60)
                ),
                pushType: nil,
                style: .standard
            )
        } catch {
            let requiresForegroundRetry: Bool
            if let authorizationError = error as? ActivityAuthorizationError {
                switch authorizationError {
                case .visibility, .missingProcessIdentifier:
                    requiresForegroundRetry = true
                default:
                    requiresForegroundRetry = false
                }
            } else {
                requiresForegroundRetry = false
            }
            let message = BackgroundDictationState.liveActivityFailureMessage(
                activitiesEnabled: ActivityAuthorizationInfo().areActivitiesEnabled,
                requiresForegroundRetry: requiresForegroundRetry
            )
            BackgroundDictationState.fail(message, defaults: defaults)
            return Result(transcript: "", message: message)
        }

        let recorder = DictationAudioRecorder()
        let audioURL: URL
        do {
            try recorder.start()
            BackgroundDictationState.begin(defaults: defaults, now: startedAt)

            while !Task.isCancelled,
                  !BackgroundDictationState.shouldStop(defaults: defaults),
                  Date().timeIntervalSince(startedAt) < 5 * 60 {
                try? await Task.sleep(for: .milliseconds(200))
            }

            guard let stoppedURL = recorder.stop() else {
                throw BackgroundDictationError.emptyRecording
            }
            audioURL = stoppedURL
        } catch {
            let message = error.localizedDescription
            BackgroundDictationState.fail(message, defaults: defaults)
            await activity.end(nil, dismissalPolicy: .immediate)
            return Result(transcript: "", message: message)
        }

        BackgroundDictationState.setPhase(.transcribing, defaults: defaults)
        await activity.update(
            ActivityContent(
                state: .init(phase: .transcribing, startedAt: startedAt),
                staleDate: Date().addingTimeInterval(60)
            )
        )

        defer { try? FileManager.default.removeItem(at: audioURL) }
        do {
            let rawText = try await DictationTranscriber().transcribe(
                audioURL: audioURL,
                modelPath: modelPath
            )
            let options = TranscriptCleanupOptions(
                removeFillers: defaults?.object(forKey: "removeFillers") as? Bool ?? true,
                autoPunctuate: defaults?.object(forKey: "autoPunctuate") as? Bool ?? true,
                autoCapitalize: defaults?.object(forKey: "autoCapitalize") as? Bool ?? true
            )
            let transcript = TranscriptCleaner.clean(rawText, options: options)
            guard !transcript.isEmpty else { throw BackgroundDictationError.emptyTranscript }

            try TranscriptStore().save(transcript)
            defaults?.set(transcript, forKey: "pendingTranscription")
            defaults?.set(Date().timeIntervalSince1970, forKey: "pendingTranscriptionDate")
            UIPasteboard.general.string = transcript
            BackgroundDictationState.finish(defaults: defaults)
            await activity.end(
                ActivityContent(
                    state: .init(phase: .ready, startedAt: startedAt),
                    staleDate: nil
                ),
                dismissalPolicy: .after(Date().addingTimeInterval(8))
            )
            return Result(transcript: transcript, message: "Dictation ready")
        } catch {
            let message = error.localizedDescription
            BackgroundDictationState.fail(message, defaults: defaults)
            await activity.end(nil, dismissalPolicy: .immediate)
            return Result(transcript: "", message: message)
        }
    }
}

private enum BackgroundDictationError: LocalizedError {
    case emptyRecording
    case emptyTranscript

    var errorDescription: String? {
        switch self {
        case .emptyRecording: "The recording was empty. Please try again."
        case .emptyTranscript: "I didn't hear any speech. Please try again."
        }
    }
}
