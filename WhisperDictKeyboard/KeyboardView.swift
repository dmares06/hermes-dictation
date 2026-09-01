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
                showsNextKeyboard: state.showsNextKeyboard,
                onInsert: onInsert,
                onDelete: onDelete,
                onNextKeyboard: onNextKeyboard,
                onKeyFeedback: onKeyFeedback
            )
            .frame(height: KeyGridView.preferredHeight)
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

/// Hosts the UIKit key grid.
///
/// The grid owns its own shift and 123 state and reports only what the rest
/// of the keyboard needs, so pressing a key never re-enters SwiftUI.
private struct KeyGrid: UIViewRepresentable {
    let showsNextKeyboard: Bool
    let onInsert: (String) -> Void
    let onDelete: () -> Void
    let onNextKeyboard: () -> Void
    let onKeyFeedback: () -> Void

    func makeUIView(context: Context) -> KeyGridView {
        let view = KeyGridView()
        view.delegate = context.coordinator
        view.showsNextKeyboard = showsNextKeyboard
        return view
    }

    func updateUIView(_ view: KeyGridView, context: Context) {
        context.coordinator.owner = self
        view.showsNextKeyboard = showsNextKeyboard
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(owner: self)
    }

    /// Holds the current closures so the grid always calls into the latest
    /// ones without being rebuilt.
    final class Coordinator: KeyGridViewDelegate {
        var owner: KeyGrid

        init(owner: KeyGrid) {
            self.owner = owner
        }

        func keyGrid(_ grid: KeyGridView, didInsert text: String) {
            owner.onInsert(text)
        }

        func keyGridDidDelete(_ grid: KeyGridView) {
            owner.onDelete()
        }

        func keyGridDidRequestNextKeyboard(_ grid: KeyGridView) {
            owner.onNextKeyboard()
        }

        func keyGridDidTouchKey(_ grid: KeyGridView) {
            owner.onKeyFeedback()
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
