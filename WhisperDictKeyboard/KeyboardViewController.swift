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
    // The dictionary lives inside this actor and every lookup runs there,
    // off the thread that draws keystrokes.
    private let spellWorker = SpellWorker()
    /// What the last completed lookup decided about the word under the
    /// cursor, so the space that ends it can apply a correction without a
    /// dictionary lookup on the keystroke itself. A `nil` correction means
    /// the word checked out clean. Cleared on every edit: a decision may
    /// only govern the exact word instance it was computed against, never a
    /// later occurrence of the same text.
    private var pendingCorrection: (word: String, correction: String?)?
    /// The word whose correction the user refused by tapping the literal.
    /// The strip must not re-offer it and the next terminator must not apply
    /// it — even if the word is edited and restored in between. The refusal
    /// lives until its word is committed or abandoned.
    private var refusedWord: String?
    /// The correction racing to land behind an already-typed terminator.
    /// Tracked so the next keystroke can cancel it instead of letting stale
    /// lookups pile up on the spell worker.
    private var behindTerminatorFix: Task<Void, Never>?
    private let keyFeedback = UIImpactFeedbackGenerator(style: .light)
    private var suggestionRefresh: Task<Void, Never>?
    /// Long enough for a burst of keystrokes to collapse into one dictionary
    /// lookup, short enough that the strip still feels live.
    private static let suggestionDelay: Duration = .milliseconds(60)

    override func viewDidLoad() {
        super.viewDidLoad()
        let keyboard = KeyboardView(
            state: keyboardState,
            onOpenRecorder: { [weak self] in self?.openRecorder() },
            onInsert: { [weak self] text in self?.insertText(text) },
            onDelete: { [weak self] in self?.deleteBackward() },
            onNextKeyboard: { [weak self] in self?.advanceToNextInputMode() },
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
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        // Covers the cursor moving, another keyboard typing, or the field
        // being cleared — none of which route through insertText.
        refreshSuggestions()
    }

    private func refreshSharedTranscript() {
        // @Observable fires a re-render on every write, changed or not, so
        // only real changes may touch the state.
        setIfChanged(\.latestTranscript, to: transcriptStore.latest?.text ?? "")
        setIfChanged(\.showsNextKeyboard, to: needsInputModeSwitchKey)
        setIfChanged(\.keyboardColor, to: appearanceStore.keyboardColor)
        setIfChanged(\.recordButtonColor, to: appearanceStore.recordButtonColor)
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
            // A refusal lives exactly until its word is committed: this
            // terminator is that commit, and it must pass through untouched.
            let refused = !word.isEmpty && word == refusedWord
            if !word.isEmpty { refusedWord = nil }
            if !refused {
                if let pending = pendingCorrection, pending.word == word {
                    if let correction = pending.correction {
                        perform(KeyboardAutocorrect.replacement(of: word, with: correction, followedBy: text))
                        refreshSuggestions()
                        return
                    }
                    // The word checked out clean: straight through below.
                } else if word.count >= 2 {
                    // Typing outran the debounced lookup. The keystroke must
                    // never wait on the dictionary, so the terminator lands
                    // now and the correction, if any, follows right behind.
                    perform(KeyboardTextProcessor.edit(for: text, contextBeforeInput: context))
                    refreshSuggestions()
                    correctBehindTerminator(word: word, terminator: text)
                    return
                }
            }
        }

        perform(KeyboardTextProcessor.edit(for: text, contextBeforeInput: context))
        refreshSuggestions()
    }

    /// Applies a correction whose terminator already landed — but only while
    /// the word is still the last thing before the cursor. If the typist has
    /// moved on, silently rewriting text behind them is worse than missing
    /// one fix.
    private func correctBehindTerminator(word: String, terminator: String) {
        behindTerminatorFix?.cancel()
        behindTerminatorFix = Task { @MainActor [weak self] in
            // A canceled fix must not still queue its lookup on the worker.
            guard !Task.isCancelled, let self,
                  let correction = await self.spellWorker.autocorrection(for: word),
                  !Task.isCancelled
            else { return }
            let context = self.textDocumentProxy.documentContextBeforeInput ?? ""
            guard context.hasSuffix(word + terminator) else { return }
            self.perform(KeyboardAutocorrect.replacementBehindTerminator(
                of: word, with: correction, terminator: terminator
            ))
        }
    }

    /// Swaps the word being typed for a tapped suggestion. Tapping the
    /// literal is how a correction is refused, so it must clear the strip
    /// rather than re-offer the same choice.
    private func apply(_ suggestion: KeyboardSuggestion) {
        playKeyFeedback()
        let word = KeyboardAutocorrect.currentWord(before: textDocumentProxy.documentContextBeforeInput)
        guard !word.isEmpty else { return }
        if suggestion.isLiteral {
            // Refusing the correction has to stick: the next terminator
            // consults this and leaves the word exactly as typed.
            refusedWord = word
            pendingCorrection = nil
        } else {
            perform(KeyboardAutocorrect.replacement(of: word, with: suggestion.text))
            pendingCorrection = nil
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

    /// The dictionary lookups behind the strip cost tens of milliseconds,
    /// which is a stutter if paid on every keystroke. They run on the spell
    /// worker a beat after the last key — never on the keystroke's thread —
    /// and land only if the word is still the same one.
    private func refreshSuggestions() {
        suggestionRefresh?.cancel()
        // The text moved: a fix racing toward the old terminator is stale,
        // and whatever the last lookup decided no longer describes what is
        // under the cursor. Only a fresh, completed lookup may repopulate it.
        behindTerminatorFix?.cancel()
        pendingCorrection = nil
        let word = KeyboardAutocorrect.currentWord(before: textDocumentProxy.documentContextBeforeInput)
        // An abandoned word releases its refusal; an edited-but-restored one
        // keeps it, so refusing a correction sticks through a typo round-trip.
        if word.isEmpty { refusedWord = nil }
        guard word.count >= 2, word != refusedWord else {
            if !keyboardState.suggestions.isEmpty { keyboardState.suggestions = [] }
            return
        }
        suggestionRefresh = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.suggestionDelay)
            guard !Task.isCancelled, let self else { return }
            let current = KeyboardAutocorrect.currentWord(before: self.textDocumentProxy.documentContextBeforeInput)
            guard current == word else { return }
            let suggestions = await self.spellWorker.suggestions(for: word)
            // The word may have moved on — or been refused — while the
            // dictionary was thinking.
            guard !Task.isCancelled,
                  word != self.refusedWord,
                  KeyboardAutocorrect.currentWord(before: self.textDocumentProxy.documentContextBeforeInput) == word
            else { return }
            self.pendingCorrection = (word, suggestions.first(where: \.isAutocorrect)?.text)
            if self.keyboardState.suggestions != suggestions {
                self.keyboardState.suggestions = suggestions
            }
        }
    }

    /// The click and tap the system keyboard gives, which is most of why one
    /// feels responsive. `playInputClick` respects the user's keyboard-sound
    /// setting on its own; the haptic needs Full Access and is silently
    /// ignored without it.
    // MARK: - In-keyboard dictation

    private func playKeyFeedback() {
        UIDevice.current.playInputClick()
        keyFeedback.impactOccurred(intensity: 0.6)
        keyFeedback.prepare()
    }

    /// Writes only when the value differs: this runs from a ¼-second timer,
    /// and an unconditional write would re-render the keyboard four times a
    /// second whether anything happened or not.
    private func setIfChanged<Value: Equatable>(
        _ keyPath: ReferenceWritableKeyPath<KeyboardState, Value>,
        to value: Value
    ) {
        guard keyboardState[keyPath: keyPath] != value else { return }
        keyboardState[keyPath: keyPath] = value
    }

    private func refreshBackgroundSession() {
        let phase = BackgroundDictationState.phase()
        let previousPhase = keyboardState.backgroundPhase
        if phase != previousPhase {
            keyboardState.backgroundPhase = phase
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
}
