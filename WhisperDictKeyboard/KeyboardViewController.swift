import Observation
import SwiftUI
import UIKit

final class KeyboardViewController: UIInputViewController {
    private var hostingController: UIHostingController<KeyboardView>?
    private let keyboardState = KeyboardState()
    private let transcriptStore = TranscriptStore()
    private let appearanceStore = AppearanceStore()
    private var sessionTimer: Timer?
    private var insertionGate = KeyboardTranscriptInsertionGate(currentRevision: 0)

    override func viewDidLoad() {
        super.viewDidLoad()
        let keyboard = KeyboardView(
            state: keyboardState,
            onOpenRecorder: { [weak self] in self?.openRecorder() },
            onInsert: { [weak self] text in self?.insertText(text) },
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
        let currentRevision = BackgroundDictationState.sharedDefaults?
            .double(forKey: BackgroundDictationState.Keys.transcriptRevision) ?? 0
        insertionGate = KeyboardTranscriptInsertionGate(currentRevision: currentRevision)
        refreshSharedTranscript()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refreshSharedTranscript()
        startSessionTimer()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        sessionTimer?.invalidate()
        sessionTimer = nil
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
        let edit = KeyboardTextProcessor.edit(
            for: text,
            contextBeforeInput: textDocumentProxy.documentContextBeforeInput
        )
        for _ in 0..<edit.deleteBackwardCount {
            textDocumentProxy.deleteBackward()
        }
        guard !edit.insertedText.isEmpty else { return }
        textDocumentProxy.insertText(edit.insertedText)
    }

    private func refreshBackgroundSession() {
        let phase = BackgroundDictationState.phase()
        keyboardState.backgroundPhase = phase
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
}
