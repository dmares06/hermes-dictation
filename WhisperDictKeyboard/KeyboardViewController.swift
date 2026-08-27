import Observation
import SwiftUI
import UIKit

extension KeyboardViewController: UIInputViewAudioFeedback {
    var enableInputClicksWhenVisible: Bool { true }
}

final class KeyboardViewController: UIInputViewController {
    private var hostingController: UIHostingController<KeyboardView>?
    private let keyboardState = KeyboardState()
    private let transcriptStore = TranscriptStore()
    private let appearanceStore = AppearanceStore()
    private var sessionTimer: Timer?
    private var transcriptObservation: DictationSignalObservation?
    private var insertionGate = KeyboardTranscriptInsertionGate(currentRevision: 0)
    // Built once: constructing a UITextChecker loads a dictionary, which is
    // far too slow to do per keystroke.
    private let wordChecker = SystemWordChecker()
    private let keyFeedback = UIImpactFeedbackGenerator(style: .light)
    private let speech = KeyboardSpeechRecognizer()
    // Tracks what this dictation has already put in the field, so each partial
    // result becomes a minimal edit rather than a duplicate insertion.
    private var liveWriter = LiveTranscriptWriter()

    override func viewDidLoad() {
        super.viewDidLoad()
        let keyboard = KeyboardView(
            state: keyboardState,
            onOpenRecorder: { [weak self] in self?.openRecorder() },
            onInsert: { [weak self] text in self?.insertText(text) },
            onDelete: { [weak self] in self?.deleteBackward() },
            onNextKeyboard: { [weak self] in self?.advanceToNextInputMode() },
            onToggleDictation: { [weak self] in self?.toggleDictation() },
            onApplySuggestion: { [weak self] suggestion in self?.apply(suggestion) },
            onKeyFeedback: { [weak self] in self?.playKeyFeedback() }
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
        let currentRevision = BackgroundDictationState.sharedDefaults?
            .double(forKey: BackgroundDictationState.Keys.transcriptRevision) ?? 0
        insertionGate = KeyboardTranscriptInsertionGate(currentRevision: currentRevision)
        // Warming the generator here means the first keystroke taps as
        // promptly as the hundredth.
        keyFeedback.prepare()
        wireSpeechEvents()
        refreshSharedTranscript()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refreshSharedTranscript()
        startSessionTimer()
        // The timer is the fallback; this is what makes the text land the
        // moment the app has it. The handler runs off the main thread.
        transcriptObservation = DictationSignalCenter.observe(.transcriptReady) { [weak self] in
            DispatchQueue.main.async { self?.refreshSharedTranscript() }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        sessionTimer?.invalidate()
        sessionTimer = nil
        transcriptObservation = nil
        // Leaving the field with the microphone open would keep recording
        // into a text field the user can no longer see.
        if speech.isListening { speech.cancel() }
        endDictation()
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        // Covers the cursor moving, another keyboard typing, or the field
        // being cleared — none of which route through insertText.
        refreshSuggestions()
    }

    private func refreshSharedTranscript() {
        keyboardState.latestTranscript = transcriptStore.latest?.text ?? ""
        keyboardState.showsNextKeyboard = needsInputModeSwitchKey
        keyboardState.keyboardColor = appearanceStore.keyboardColor
        keyboardState.recordButtonColor = appearanceStore.recordButtonColor
        refreshBackgroundSession()
        if keyboardState.handoffStatus == nil,
           keyboardState.backgroundPhase == .idle || keyboardState.backgroundPhase == .ready {
            keyboardState.handoffStatus = keyboardState.isListening
                ? KeyboardHandoffGuidance.listeningMessage()
                : KeyboardHandoffGuidance.idleMessage(hasFullAccess: hasFullAccess)
        }
    }

    private func openRecorder() {
        let listening = ListeningWindowState.isAlive()
        switch KeyboardHandoffGuidance.recorderAction(for: BackgroundDictationState.phase(), listening: listening) {
        case .requestStart:
            ListeningWindowState.requestStart()
            DictationSignalCenter.post(.start)
            keyboardState.handoffStatus = "Starting…"
        case .requestStop:
            BackgroundDictationState.requestStop()
            DictationSignalCenter.post(.stop)
            keyboardState.handoffStatus = "Stopping…"
        case .showTranscribing:
            keyboardState.handoffStatus = "Transcribing on this iPhone…"
        case .showFailure:
            keyboardState.handoffStatus = BackgroundDictationState.sharedDefaults?
                .string(forKey: BackgroundDictationState.Keys.errorMessage) ?? "Dictation failed. Try your Action Button again."
        case .showActionButtonGuidance:
            keyboardState.handoffStatus = KeyboardHandoffGuidance.micButtonMessage(
                hasFullAccess: hasFullAccess
            )
        }
        refreshBackgroundSession()
    }

    private func startSessionTimer() {
        sessionTimer?.invalidate()
        sessionTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.refreshBackgroundSession()
        }
    }

    private func insertText(_ text: String) {
        let context = textDocumentProxy.documentContextBeforeInput

        // A terminator is the moment a word is finished, and so the only
        // moment a correction can be applied without fighting the typist.
        if KeyboardAutocorrect.isWordTerminator(text) {
            let word = KeyboardAutocorrect.currentWord(before: context)
            if let correction = KeyboardAutocorrect.autocorrection(for: word, checker: wordChecker) {
                perform(KeyboardAutocorrect.replacement(of: word, with: correction, followedBy: text))
                refreshSuggestions()
                return
            }
        }

        perform(KeyboardTextProcessor.edit(for: text, contextBeforeInput: context))
        refreshSuggestions()
    }

    /// Swaps the word being typed for a tapped suggestion. Tapping the
    /// literal is how a correction is refused, so it must clear the strip
    /// rather than re-offer the same choice.
    private func apply(_ suggestion: KeyboardSuggestion) {
        playKeyFeedback()
        let word = KeyboardAutocorrect.currentWord(before: textDocumentProxy.documentContextBeforeInput)
        guard !word.isEmpty else { return }
        if !suggestion.isLiteral {
            perform(KeyboardAutocorrect.replacement(of: word, with: suggestion.text))
        }
        keyboardState.suggestions = []
    }

    private func deleteBackward() {
        textDocumentProxy.deleteBackward()
        refreshSuggestions()
    }

    private func perform(_ edit: KeyboardTextEdit) {
        for _ in 0..<edit.deleteBackwardCount {
            textDocumentProxy.deleteBackward()
        }
        guard !edit.insertedText.isEmpty else { return }
        textDocumentProxy.insertText(edit.insertedText)
    }

    private func refreshSuggestions() {
        let word = KeyboardAutocorrect.currentWord(before: textDocumentProxy.documentContextBeforeInput)
        keyboardState.suggestions = KeyboardAutocorrect.suggestions(for: word, checker: wordChecker)
    }

    /// The click and tap the system keyboard gives, which is most of why one
    /// feels responsive. `playInputClick` respects the user's keyboard-sound
    /// setting on its own; the haptic needs Full Access and is silently
    /// ignored without it.
    // MARK: - In-keyboard dictation

    /// Starts or stops recording inside the keyboard.
    ///
    /// This is the path with no cold start: with Full Access the extension may
    /// use the microphone itself, and Apple's recognizer fits in an
    /// extension's memory budget where a Whisper model does not. The Action
    /// Button handoff stays for when accuracy matters more than immediacy.
    private func toggleDictation() {
        playKeyFeedback()
        if speech.isListening {
            keyboardState.dictationPhase = .finishing
            speech.stop()
            return
        }

        if let blocker = KeyboardDictationGate.blocker(
            hasFullAccess: hasFullAccess,
            microphoneAuthorized: KeyboardSpeechRecognizer.microphoneAuthorized,
            speechAuthorized: KeyboardSpeechRecognizer.speechAuthorized,
            recognizerAvailable: speech.isRecognizerAvailable
        ) {
            keyboardState.handoffStatus = blocker.message
            return
        }

        liveWriter = LiveTranscriptWriter()
        keyboardState.dictationPhase = .starting
        keyboardState.handoffStatus = "Starting…"
        speech.start()
    }

    private func wireSpeechEvents() {
        speech.onEvent = { [weak self] event in
            guard let self else { return }
            switch event {
            case .started:
                self.keyboardState.dictationPhase = .listening
                self.keyboardState.handoffStatus = "Listening — speak, then tap Stop"
            case .partial(let text):
                self.applyLive(text)
            case .finished(let text):
                self.applyLive(text)
                self.finishDictation()
            case .failed(let message):
                self.keyboardState.handoffStatus = message
                self.endDictation()
            }
        }
    }

    /// Rewrites only what changed since the last partial result, so the text
    /// updates in place instead of the field filling with repeated guesses.
    private func applyLive(_ text: String) {
        let edit = liveWriter.edit(replacingWith: text)
        guard !edit.isNoOp else { return }
        for _ in 0..<edit.deleteCount {
            textDocumentProxy.deleteBackward()
        }
        if !edit.insertText.isEmpty {
            textDocumentProxy.insertText(edit.insertText)
        }
    }

    /// Applies the same cleanup a Whisper transcript gets, then leaves a
    /// trailing space so typing or dictating can continue naturally.
    private func finishDictation() {
        let edit = liveWriter.finishEdit()
        for _ in 0..<edit.deleteCount {
            textDocumentProxy.deleteBackward()
        }
        if !edit.insertText.isEmpty {
            textDocumentProxy.insertText(edit.insertText)
        }
        let dictated = liveWriter.insertedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !dictated.isEmpty {
            // Dictation done here should show up in history like any other.
            try? transcriptStore.save(dictated)
        }
        keyboardState.handoffStatus = nil
        endDictation()
    }

    private func endDictation() {
        keyboardState.dictationPhase = .idle
        liveWriter = LiveTranscriptWriter()
        refreshSuggestions()
    }

    private func playKeyFeedback() {
        UIDevice.current.playInputClick()
        keyFeedback.impactOccurred(intensity: 0.6)
        keyFeedback.prepare()
    }

    private func refreshBackgroundSession() {
        let phase = BackgroundDictationState.phase()
        let previousPhase = keyboardState.backgroundPhase
        keyboardState.backgroundPhase = phase
        if phase != previousPhase {
            // "Starting…" must never outlive the outcome it was waiting for.
            switch phase {
            case .recording: keyboardState.handoffStatus = "Listening… tap Stop when you're done"
            case .transcribing: keyboardState.handoffStatus = "Transcribing on this iPhone…"
            case .failed:
                keyboardState.handoffStatus = BackgroundDictationState.sharedDefaults?
                    .string(forKey: BackgroundDictationState.Keys.errorMessage) ?? "Dictation failed."
            case .idle, .ready: break
            }
        }
        let listening = ListeningWindowState.isAlive()
        if listening != keyboardState.isListening {
            keyboardState.isListening = listening
            if phase == .idle || phase == .ready {
                keyboardState.handoffStatus = listening
                    ? KeyboardHandoffGuidance.listeningMessage()
                    : KeyboardHandoffGuidance.idleMessage(hasFullAccess: hasFullAccess)
            }
        }

        let defaults = BackgroundDictationState.sharedDefaults
        let startedAt = defaults?.double(forKey: BackgroundDictationState.Keys.startedAt) ?? 0
        let revision = defaults?.double(forKey: BackgroundDictationState.Keys.transcriptRevision) ?? 0
        guard insertionGate.shouldInsert(
            phase: phase,
            sessionStartedAt: startedAt,
            transcriptRevision: revision
        ) else { return }
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
    var isListening = false
    var suggestions: [KeyboardSuggestion] = []
    var dictationPhase: KeyboardDictationPhase = .idle
}
