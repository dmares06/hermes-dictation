import Observation
import SwiftUI
import UIKit

final class KeyboardViewController: UIInputViewController {
    private var hostingController: UIHostingController<KeyboardView>?
    private let keyboardState = KeyboardState()
    private let transcriptStore = TranscriptStore()
    private let appearanceStore = AppearanceStore()
    private var sessionTimer: Timer?
    private var lastTranscriptRevision = 0.0

    override func viewDidLoad() {
        super.viewDidLoad()
        let keyboard = KeyboardView(
            state: keyboardState,
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
    }

    private func openRecorder() {
        switch BackgroundDictationState.phase() {
        case .recording:
            BackgroundDictationState.requestStop()
            keyboardState.handoffStatus = "Stopping…"
        case .transcribing:
            keyboardState.handoffStatus = "Transcribing on this iPhone…"
        case .failed:
            keyboardState.handoffStatus = BackgroundDictationState.sharedDefaults?
                .string(forKey: BackgroundDictationState.Keys.errorMessage) ?? "Dictation failed. Try your Action Button again."
        case .idle, .ready:
            guard let url = URL(string: "whisperdict://record") else { return }
            keyboardState.handoffStatus = "Opening WhisperDict…"
            extensionContext?.open(url) { [weak self] opened in
                guard !opened else { return }
                self?.keyboardState.handoffStatus = "Open WhisperDict once, then try again."
            }
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
}
