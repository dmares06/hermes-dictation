import SwiftUI

/// Composes the keyboard out of pieces that re-render independently.
///
/// This body reads no observable state at all — deliberately. The top bar
/// reads the transcript, status and suggestions; the grid reads pressed keys
/// and shift. Kept separate, a keystroke redraws only the grid and a
/// suggestion only the strip, instead of every touch re-rendering the whole
/// keyboard.
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

    var body: some View {
        VStack(spacing: 7) {
            KeyboardTopBar(
                state: state,
                onOpenRecorder: onOpenRecorder,
                onInsert: onInsert,
                onApplySuggestion: onApplySuggestion
            )
            KeyGrid(
                state: state,
                onInsert: onInsert,
                onDelete: onDelete,
                onNextKeyboard: onNextKeyboard,
                onKeyFeedback: onKeyFeedback
            )
        }
        .padding(.horizontal, 5)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .background(KeyboardBackdrop(state: state))
    }
}

/// Reads the appearance color in its own body so a color change repaints
/// this rectangle alone, not the keyboard above it.
private struct KeyboardBackdrop: View {
    let state: KeyboardState

    var body: some View {
        Color(appearanceColor: state.keyboardColor).opacity(0.24)
    }
}

/// The recorder handoff controls and the suggestion/status row.
private struct KeyboardTopBar: View {
    let state: KeyboardState
    let onOpenRecorder: () -> Void
    let onInsert: (String) -> Void
    let onApplySuggestion: (KeyboardSuggestion) -> Void

    /// The row above the keys never changes height: the suggestions and the
    /// dictation status take turns inside it, so the keyboard stays put
    /// instead of jumping every time a word starts or finishes.
    private static let suggestionSlotHeight: CGFloat = 36

    var body: some View {
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
            // the scarcest thing in a keyboard. The row is a fixed slot
            // so swapping them never resizes the keyboard.
            ZStack {
                if state.suggestions.isEmpty {
                    Text(state.handoffStatus ?? defaultHandoffStatus)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    SuggestionStrip(
                        suggestions: state.suggestions,
                        onApply: onApplySuggestion
                    )
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: Self.suggestionSlotHeight)
            .clipped()
        }
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
}

/// The keys, their touch surface, and the shift/mode state they share.
private struct KeyGrid: View {
    let state: KeyboardState
    let onInsert: (String) -> Void
    let onDelete: () -> Void
    let onNextKeyboard: () -> Void
    let onKeyFeedback: () -> Void

    @State private var mode: KeyboardMode = .letters
    @State private var isShifted = false
    /// Keys with a finger on them right now; several at once while typing fast.
    @State private var pressedKeys: Set<KeyboardKey> = []
    @State private var deleteRepeat: Task<Void, Never>?

    /// The caps draw; the touch surface over them types. Each cap reports
    /// where it is so the surface can turn a finger into a key.
    var body: some View {
        VStack(spacing: 7) {
            ForEach(Array(layout.rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 5) {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, key in
                        KeyCap(
                            key: key,
                            shifted: isShifted,
                            numericMode: mode == .numbers,
                            showsNextKeyboard: state.showsNextKeyboard,
                            isPressed: pressedKeys.contains(key),
                            action: { handle(key) }
                        )
                        .anchorPreference(key: KeyFramesKey.self, value: .bounds) { [key: $0] }
                    }
                }
            }
        }
        .overlayPreferenceValue(KeyFramesKey.self) { anchors in
            GeometryReader { proxy in
                KeyTouchSurface(
                    frames: anchors.mapValues { proxy[$0] },
                    onPress: press,
                    onRelease: release
                )
            }
        }
        .onDisappear {
            pressedKeys = []
            stopRepeatingDelete()
        }
    }

    /// A key fires the instant the finger lands, never on lift: firing on
    /// touch-up is what makes fast typing feel like it drops characters.
    private func press(_ key: KeyboardKey) {
        guard !pressedKeys.contains(key) else { return }
        pressedKeys.insert(key)
        onKeyFeedback()
        if key == .delete {
            startRepeatingDelete()
        } else {
            handle(key)
        }
    }

    private func release(_ key: KeyboardKey) {
        pressedKeys.remove(key)
        if key == .delete { stopRepeatingDelete() }
    }

    private func startRepeatingDelete() {
        guard deleteRepeat == nil else { return }
        onDelete()
        // Held delete accelerates the way the system keyboard does: a pause
        // long enough to mean "I meant one character", then a steady run.
        deleteRepeat = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            while !Task.isCancelled {
                onDelete()
                try? await Task.sleep(for: .milliseconds(70))
            }
        }
    }

    private func stopRepeatingDelete() {
        deleteRepeat?.cancel()
        deleteRepeat = nil
    }

    private var layout: KeyboardLayout {
        mode == .letters ? .alphabetic : .numeric
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

/// Where each cap ended up, in the grid's coordinates, for the touch surface.
private struct KeyFramesKey: PreferenceKey {
    static let defaultValue: [KeyboardKey: Anchor<CGRect>] = [:]
    static func reduce(value: inout [KeyboardKey: Anchor<CGRect>], nextValue: () -> [KeyboardKey: Anchor<CGRect>]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// A key as drawn. Touches are handled by the surface above the grid, so
/// this only has to look right — pressed or not — and answer VoiceOver.
private struct KeyCap: View {
    let key: KeyboardKey
    let shifted: Bool
    let numericMode: Bool
    let showsNextKeyboard: Bool
    let isPressed: Bool
    let action: () -> Void

    var body: some View {
        keyCap
            .overlay(alignment: .top) { popup }
            .zIndex(isPressed ? 1 : 0)
            .opacity(key == .globe && !showsNextKeyboard ? 0.45 : 1)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityAddTraits(.isButton)
            // VoiceOver drives the key through this, not the touch surface.
            .accessibilityAction { action() }
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

    private var minimumWidth: CGFloat {
        switch key {
        case .space: 120
        case .returnKey, .modeChange: 52
        default: 28
        }
    }

    /// A pressed cap darkens the way the system keyboard's does, so the
    /// finger gets an answer even on keys with no popup.
    private var backgroundColor: Color {
        switch key {
        case .character, .space:
            isPressed ? Color(uiColor: .systemGray4) : Color(uiColor: .systemBackground)
        default:
            isPressed ? Color(uiColor: .systemBackground) : Color(uiColor: .systemGray3)
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
