import Observation
import SwiftUI
import UIKit

final class KeyboardViewController: UIInputViewController {
    private var hostingController: UIHostingController<KeyboardView>?
    private let keyboardState = KeyboardState()
    private let transcriptStore = TranscriptStore()
    private let appearanceStore = AppearanceStore()
    private let speechRecognizer = KeyboardSpeechRecognizer()
    private var liveWriter = LiveTranscriptWriter()
    private var sessionTimer: Timer?
    private var lastTranscriptRevision = 0.0

    override func viewDidLoad() {
        super.viewDidLoad()
        let keyboard = KeyboardView(
            state: keyboardState,
            onToggleMic: { [weak self] in self?.toggleLiveDictation() },
            onOpenRecorder: { [weak self] in self?.openRecorder() },
            onInsert: { [weak self] text in self?.textDocumentProxy.insertText(text) },
            onDelete: { [weak self] in self?.textDocumentProxy.deleteBackward() },
            onNextKeyboard: { [weak self] in self?.advanceToNextInputMode() }
        )
        let hosting = UIHostingController(rootView: keyboard)
        hosting.view.backgroundColor = .clear
        addChild(hosting)
        view.addSubview(hosting.view)
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hosting.view.topAnchor.constraint(equalTo: view.topAnchor),
            hosting.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        hosting.didMove(toParent: self)
        hostingController = hosting
        lastTranscriptRevision = BackgroundDictationState.sharedDefaults?
            .double(forKey: BackgroundDictationState.Keys.transcriptRevision) ?? 0
        configureSpeechRecognizer()
        refreshSharedTranscript()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refreshSharedTranscript()
        startSessionTimer()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        speechRecognizer.cancel()
        keyboardState.dictationPhase = .idle
        sessionTimer?.invalidate()
        sessionTimer = nil
    }

    // MARK: - In-keyboard live dictation

    private func configureSpeechRecognizer() {
        speechRecognizer.onEvent = { [weak self] event in
            guard let self else { return }
            switch event {
            case .started:
                keyboardState.dictationPhase = .listening
                keyboardState.handoffStatus = "Listening… tap the mic to stop"
            case .partial(let text):
                apply(liveWriter.edit(replacingWith: text))
            case .finished(let text):
                apply(liveWriter.edit(replacingWith: text))
                apply(liveWriter.finishEdit())
                let finalText = liveWriter.insertedText.trimmingCharacters(in: .whitespaces)
                if !finalText.isEmpty {
                    try? transcriptStore.save(finalText)
                    lastTranscriptRevision = BackgroundDictationState.sharedDefaults?
                        .double(forKey: BackgroundDictationState.Keys.transcriptRevision) ?? lastTranscriptRevision
                    keyboardState.latestTranscript = finalText
                }
                liveWriter = LiveTranscriptWriter()
                keyboardState.dictationPhase = .idle
                keyboardState.handoffStatus = finalText.isEmpty ? nil : "Inserted"
            case .failed(let message):
                liveWriter = LiveTranscriptWriter()
                keyboardState.dictationPhase = .idle
                keyboardState.handoffStatus = message
            }
        }
    }

    private func toggleLiveDictation() {
        switch keyboardState.dictationPhase {
        case .listening, .starting:
            keyboardState.dictationPhase = .finishing
            keyboardState.handoffStatus = "Finishing…"
            speechRecognizer.stop()
        case .finishing:
            break
        case .idle:
            if let blocker = KeyboardDictationGate.blocker(
                hasFullAccess: hasFullAccess,
                microphoneAuthorized: KeyboardSpeechRecognizer.microphoneAuthorized,
                speechAuthorized: KeyboardSpeechRecognizer.speechAuthorized,
                recognizerAvailable: speechRecognizer.isRecognizerAvailable
            ) {
                keyboardState.handoffStatus = blocker.message
                return
            }
            liveWriter = LiveTranscriptWriter()
            keyboardState.dictationPhase = .starting
            keyboardState.handoffStatus = "Starting microphone…"
            speechRecognizer.start()
        }
    }

    private func apply(_ edit: LiveTranscriptWriter.Edit) {
        guard !edit.isNoOp else { return }
        for _ in 0..<edit.deleteCount {
            textDocumentProxy.deleteBackward()
        }
        if !edit.insertText.isEmpty {
            textDocumentProxy.insertText(edit.insertText)
        }
    }

    // MARK: - Action Button handoff (WhisperKit in the main app)

    private func refreshSharedTranscript() {
        keyboardState.latestTranscript = transcriptStore.latest?.text ?? ""
        keyboardState.showsNextKeyboard = needsInputModeSwitchKey
        keyboardState.keyboardColor = appearanceStore.keyboardColor
        keyboardState.recordButtonColor = appearanceStore.recordButtonColor
        refreshBackgroundSession()
        if keyboardState.handoffStatus == nil,
           keyboardState.dictationPhase == .idle,
           keyboardState.backgroundPhase == .idle || keyboardState.backgroundPhase == .ready {
            keyboardState.handoffStatus = hasFullAccess
                ? "Tap the mic to dictate right here"
                : KeyboardDictationBlocker.needsFullAccess.message
        }
    }

    private func openRecorder() {
        switch KeyboardHandoffGuidance.recorderAction(for: BackgroundDictationState.phase()) {
        case .requestStop:
            BackgroundDictationState.requestStop()
            keyboardState.handoffStatus = "Stopping…"
        case .showTranscribing:
            keyboardState.handoffStatus = "Transcribing on this iPhone…"
        case .showFailure:
            keyboardState.handoffStatus = BackgroundDictationState.sharedDefaults?
                .string(forKey: BackgroundDictationState.Keys.errorMessage) ?? "Dictation failed. Try your Action Button again."
        case .showActionButtonGuidance:
            keyboardState.handoffStatus = "Press your iPhone Action Button to open WhisperDict and record."
        }
        refreshBackgroundSession()
    }

    private func startSessionTimer() {
        sessionTimer?.invalidate()
        sessionTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.refreshBackgroundSession()
        }
    }

    private func refreshBackgroundSession() {
        let phase = BackgroundDictationState.phase()
        keyboardState.backgroundPhase = phase

        let defaults = BackgroundDictationState.sharedDefaults
        let revision = defaults?.double(forKey: BackgroundDictationState.Keys.transcriptRevision) ?? 0
        guard revision > lastTranscriptRevision else { return }
        lastTranscriptRevision = revision
        keyboardState.latestTranscript = transcriptStore.latest?.text ?? ""
        guard !keyboardState.latestTranscript.isEmpty else { return }
        textDocumentProxy.insertText(keyboardState.latestTranscript)
        keyboardState.handoffStatus = "Inserted"
    }
}

@MainActor
@Observable
final class KeyboardState {
    var latestTranscript = ""
    var showsNextKeyboard = true
    var keyboardColor = AppearanceColor.defaultKeyboard
    var recordButtonColor = AppearanceColor.defaultRecordButton
    var handoffStatus: String?
    var backgroundPhase: BackgroundDictationPhase = .idle
    var dictationPhase: KeyboardDictationPhase = .idle
}
