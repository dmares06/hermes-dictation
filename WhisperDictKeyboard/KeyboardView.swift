import SwiftUI

struct KeyboardView: View {
    let state: KeyboardState
    let onOpenRecorder: () -> Void
    let onInsert: (String) -> Void
    let onDelete: () -> Void
    let onNextKeyboard: () -> Void
    /// Replaces the word being typed with a tapped suggestion.
    let onApplySuggestion: (KeyboardSuggestion) -> Void
    /// The click and tap a key is expected to produce. Fired on touch down
    /// with the keystroke, never after it.
    let onKeyFeedback: () -> Void

    @State private var mode: KeyboardMode = .letters
    @State private var isShifted = false

    var body: some View {
        VStack(spacing: 7) {
            VStack(spacing: 4) {
                HStack(spacing: 8) {
                    // Hands off to the app's recorder. It is the only way to
                    // dictate from a keyboard: iOS refuses a keyboard extension
                    // the microphone even with Full Access (AVAudioEngine fails
                    // with error 2003329396), so there is no in-keyboard path.
                    Button(action: onOpenRecorder) {
                        recordControlLabel
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(recordButtonAccessibilityHint)

                    if !state.latestTranscript.isEmpty {
                        Button {
                            onInsert(state.latestTranscript)
                        } label: {
                            Image(systemName: "text.insert")
                                .font(.footnote.weight(.semibold))
                                .frame(minWidth: 38, minHeight: 34)
                                .background(recordButtonColor.opacity(0.16), in: RoundedRectangle(cornerRadius: 9))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Insert latest transcript")
                        .accessibilityHint("Inserts the most recent transcript created in WhisperDict")
                    }

                    Spacer(minLength: 0)
                }

                // The strip and the dictation status share a row: only one of
                // them is ever relevant, and vertical space above the keys is
                // the scarcest thing in a keyboard.
                if state.suggestions.isEmpty {
                    Text(state.handoffStatus ?? defaultHandoffStatus)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    SuggestionStrip(
                        suggestions: state.suggestions,
                        onApply: onApplySuggestion
                    )
                }
            }

            ForEach(Array(layout.rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 5) {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, key in
                        KeyButton(
                            key: key,
                            shifted: isShifted,
                            numericMode: mode == .numbers,
                            showsNextKeyboard: state.showsNextKeyboard,
                            action: { handle(key) },
                            onPressFeedback: onKeyFeedback
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
        Group {
            // "Action Button" is too wide to sit beside the primary control on
            // a phone, and it is only guidance. The label earns its space when
            // the handoff is actually doing something.
            if recordButtonTitle == "Action Button" {
                Image(systemName: recordButtonIcon)
                    .frame(minWidth: 38)
            } else {
                Label(recordButtonTitle, systemImage: recordButtonIcon)
                    .lineLimit(1)
                    .padding(.horizontal, 12)
            }
        }
        .font(.footnote.weight(.semibold))
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
    let onPressFeedback: () -> Void
    @State private var repeatTask: Task<Void, Never>?
    @State private var isPressed = false

    var body: some View {
        keyCap
            // The hit area is the whole cell including the gap around the cap,
            // so a finger landing between two keys still lands on one of them.
            .contentShape(Rectangle())
            .overlay(alignment: .top) { popup }
            .zIndex(isPressed ? 1 : 0)
            .gesture(
                // A key must fire the instant the finger lands, not on lift:
                // firing on touch-up is what makes fast typing feel like it
                // drops characters, because a quick tap that slides a little
                // never completes as a tap at all. A drag with no minimum
                // distance is the only SwiftUI gesture that reports touch
                // down, and latching on `isPressed` keeps the continuous
                // stream of drag updates from repeating the keystroke.
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in press() }
                    .onEnded { _ in release() }
            )
            .opacity(key == .globe && !showsNextKeyboard ? 0.45 : 1)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityAddTraits(.isButton)
            // VoiceOver drives the key through this, not the drag gesture.
            .accessibilityAction { action() }
            .onDisappear(perform: release)
    }

    @ViewBuilder
    private var popup: some View {
        if isPressed, let popupText {
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

    private func press() {
        guard !isPressed else { return }
        isPressed = true
        onPressFeedback()
        if key == .delete {
            startRepeatingDelete()
        } else {
            action()
        }
    }

    private func release() {
        isPressed = false
        stopRepeatingDelete()
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
        // Held delete accelerates the way the system keyboard does: a pause
        // long enough to mean "I meant one character", then a steady run.
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

private struct SuggestionStrip: View {
    let suggestions: [KeyboardSuggestion]
    let onApply: (KeyboardSuggestion) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                if index > 0 {
                    Divider().frame(height: 18)
                }
                Button {
                    onApply(suggestion)
                } label: {
                    Text(suggestion.isLiteral ? "\u{201C}\(suggestion.text)\u{201D}" : suggestion.text)
                        .font(.callout)
                        // The correction that space would apply is the one
                        // worth marking, so accepting it is a decision rather
                        // than a surprise.
                        .fontWeight(suggestion.isAutocorrect ? .semibold : .regular)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, minHeight: 34)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    suggestion.isLiteral
                        ? "Keep \(suggestion.text)"
                        : "Replace with \(suggestion.text)"
                )
            }
        }
        .frame(maxWidth: .infinity)
    }
}
