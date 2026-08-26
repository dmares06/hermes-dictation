import SwiftUI

struct KeyboardView: View {
    let state: KeyboardState
    let onOpenRecorder: () -> Void
    let onInsert: (String) -> Void
    let onDelete: () -> Void
    let onNextKeyboard: () -> Void

    @State private var mode: KeyboardMode = .letters
    @State private var isShifted = false

    var body: some View {
        VStack(spacing: 7) {
            VStack(spacing: 4) {
                HStack(spacing: 8) {
                    Button(action: onOpenRecorder) {
                        recordControlLabel
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(recordButtonAccessibilityHint)

                    if !state.latestTranscript.isEmpty {
                        Button {
                            onInsert(state.latestTranscript)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "waveform.badge.mic")
                                Text("Insert latest")
                                    .fontWeight(.semibold)
                                Text(state.latestTranscript)
                                    .lineLimit(1)
                                    .foregroundStyle(.secondary)
                                Spacer(minLength: 0)
                            }
                            .font(.footnote)
                            .padding(.horizontal, 12)
                            .frame(maxWidth: .infinity, minHeight: 34)
                            .background(recordButtonColor.opacity(0.16), in: RoundedRectangle(cornerRadius: 9))
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Inserts the most recent transcript created in WhisperDict")
                    } else {
                        Spacer(minLength: 0)
                    }
                }

                Text(state.handoffStatus ?? defaultHandoffStatus)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
            }

            ForEach(Array(layout.rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 5) {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, key in
                        KeyButton(
                            key: key,
                            shifted: isShifted,
                            numericMode: mode == .numbers,
                            showsNextKeyboard: state.showsNextKeyboard,
                            action: { handle(key) }
                        )
                    }
                }
            }
        }
        .padding(.horizontal, 5)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .background(keyboardColor.opacity(0.24))
    }

    private var layout: KeyboardLayout {
        mode == .letters ? .alphabetic : .numeric
    }

    private var keyboardColor: Color {
        Color(appearanceColor: state.keyboardColor)
    }

    private var recordButtonColor: Color {
        Color(appearanceColor: state.recordButtonColor)
    }

    private var recordButtonForeground: Color {
        state.recordButtonColor.prefersDarkForeground ? .black : .white
    }

    private var activeRecordButtonColor: Color {
        state.backgroundPhase == .recording ? .red : recordButtonColor
    }

    private var recordButtonTitle: String {
        KeyboardHandoffGuidance.recorderButtonTitle(for: state.backgroundPhase, listening: state.isListening)
    }

    private var recordControlLabel: some View {
        Label(recordButtonTitle, systemImage: recordButtonIcon)
            .font(.footnote.weight(.semibold))
            .padding(.horizontal, 12)
            .frame(minHeight: 34)
            .foregroundStyle(recordButtonForeground)
            .background(activeRecordButtonColor, in: RoundedRectangle(cornerRadius: 9))
    }

    private var recordButtonIcon: String {
        switch state.backgroundPhase {
        case .recording: "stop.fill"
        case .transcribing: "ellipsis"
        case .idle, .ready, .failed: "mic.fill"
        }
    }

    private var defaultHandoffStatus: String {
        return switch state.backgroundPhase {
        case .recording: "Speak naturally, then tap Stop"
        case .transcribing: "Transcribing privately on this iPhone…"
        case .ready, .idle:
            state.isListening
                ? KeyboardHandoffGuidance.listeningMessage()
                : KeyboardHandoffGuidance.idleMessage(hasFullAccess: true)
        case .failed:
            state.isListening
                ? "Tap Talk to try again"
                : "Press the Action Button again, or open WhisperDict for details"
        }
    }

    private var recordButtonAccessibilityHint: String {
        switch state.backgroundPhase {
        case .recording: "Stops recording so WhisperDict can transcribe and insert your words"
        case .transcribing: "WhisperDict is transcribing your recording"
        case .idle, .ready, .failed:
            state.isListening
                ? "Starts recording in the background without leaving this app"
                : "Shows how to start Hermes dictation from any app"
        }
    }

    private func handle(_ key: KeyboardKey) {
        switch key {
        case .character:
            if let text = key.text(shifted: isShifted) { onInsert(text) }
            if isShifted { isShifted = false }
        case .shift:
            isShifted.toggle()
        case .delete:
            onDelete()
        case .modeChange:
            mode = mode == .letters ? .numbers : .letters
            isShifted = false
        case .globe:
            onNextKeyboard()
        case .space, .returnKey:
            if let text = key.insertedText { onInsert(text) }
        }
    }
}

private enum KeyboardMode {
    case letters
    case numbers
}

private struct KeyButton: View {
    let key: KeyboardKey
    let shifted: Bool
    let numericMode: Bool
    let showsNextKeyboard: Bool
    let action: () -> Void
    @State private var repeatTask: Task<Void, Never>?

    var body: some View {
        Group {
            if key == .delete {
                keyCap
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { _ in startRepeatingDelete() }
                            .onEnded { _ in stopRepeatingDelete() }
                    )
            } else {
                Button(action: action) { keyCap }
                    .buttonStyle(KeyPopupButtonStyle(popupText: popupText))
            }
        }
        .opacity(key == .globe && !showsNextKeyboard ? 0.45 : 1)
        .accessibilityLabel(accessibilityLabel)
        .onDisappear(perform: stopRepeatingDelete)
    }

    private var keyCap: some View {
        Group {
            switch key {
            case .shift:
                Image(systemName: shifted ? "shift.fill" : "shift")
            case .delete:
                Image(systemName: "delete.left")
            case .globe:
                Image(systemName: "globe")
            case .returnKey:
                Image(systemName: "return")
            case .modeChange:
                Text(numericMode ? "ABC" : "123")
                    .font(.caption.weight(.medium))
            case .space:
                Text("space").font(.caption)
            case .character:
                Text(key.text(shifted: shifted) ?? "")
                    .font(.title3)
            }
        }
            .frame(maxWidth: key == .space ? .infinity : nil)
            .frame(minWidth: minimumWidth, maxWidth: .infinity, minHeight: 42)
            .foregroundStyle(.primary)
            .background(backgroundColor, in: RoundedRectangle(cornerRadius: 6))
            .shadow(color: .black.opacity(0.16), radius: 0.5, y: 1)
    }

    private func startRepeatingDelete() {
        guard repeatTask == nil else { return }
        action()
        repeatTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            while !Task.isCancelled {
                action()
                try? await Task.sleep(for: .milliseconds(70))
            }
        }
    }

    private func stopRepeatingDelete() {
        repeatTask?.cancel()
        repeatTask = nil
    }

    private var minimumWidth: CGFloat {
        switch key {
        case .space: 120
        case .returnKey, .modeChange: 52
        default: 28
        }
    }

    private var backgroundColor: Color {
        switch key {
        case .character, .space: Color(uiColor: .systemBackground)
        default: Color(uiColor: .systemGray3)
        }
    }

    private var popupText: String? {
        guard case .character(let value) = key,
              value.allSatisfy(\.isLetter) else { return nil }
        return key.text(shifted: shifted)
    }

    private var accessibilityLabel: String {
        switch key {
        case .character: key.text(shifted: shifted) ?? "key"
        case .shift: "Shift"
        case .delete: "Delete"
        case .modeChange: numericMode ? "Letters" : "Numbers"
        case .globe: "Next keyboard"
        case .space: "Space"
        case .returnKey: "Return"
        }
    }
}

private struct KeyPopupButtonStyle: ButtonStyle {
    let popupText: String?

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .overlay(alignment: .top) {
                if configuration.isPressed, let popupText {
                    Text(popupText)
                        .font(.title2.weight(.medium))
                        .foregroundStyle(.primary)
                        .frame(width: 54, height: 58)
                        .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 9))
                        .shadow(color: .black.opacity(0.28), radius: 2, y: 1)
                        .offset(y: -48)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .zIndex(configuration.isPressed ? 1 : 0)
    }
}
