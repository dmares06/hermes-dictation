import Foundation

/// Live dictation that runs inside the keyboard extension itself, the way
/// Wispr Flow's iOS keyboard works: with Full Access enabled a keyboard may
/// record from the microphone, and Apple's on-device speech recognizer fits
/// inside the extension's memory budget (WhisperKit does not, so it stays in
/// the main app for the Action Button flow).
public enum KeyboardDictationPhase: Equatable, Sendable {
    case idle
    case starting
    case listening
    case finishing
}

/// Why the in-keyboard microphone cannot start right now.
public enum KeyboardDictationBlocker: Equatable, Sendable {
    case needsFullAccess
    case needsMicrophonePermission
    case needsSpeechPermission
    case recognizerUnavailable

    public var message: String {
        switch self {
        case .needsFullAccess:
            "Turn on Allow Full Access for WhisperDict in Settings → General → Keyboard to dictate here"
        case .needsMicrophonePermission:
            "Open the WhisperDict app once and allow microphone access, then return here"
        case .needsSpeechPermission:
            "Open the WhisperDict app once and allow speech recognition, then return here"
        case .recognizerUnavailable:
            "Speech recognition is unavailable right now. Use your Action Button instead."
        }
    }
}

public enum KeyboardDictationGate {
    /// Returns the first blocker preventing in-keyboard dictation, or nil when
    /// the microphone can start. `microphoneAuthorized`/`speechAuthorized` are
    /// nil while the permission is still undetermined, which is allowed
    /// through so the extension can trigger the request.
    public static func blocker(
        hasFullAccess: Bool,
        microphoneAuthorized: Bool?,
        speechAuthorized: Bool?,
        recognizerAvailable: Bool
    ) -> KeyboardDictationBlocker? {
        guard hasFullAccess else { return .needsFullAccess }
        if microphoneAuthorized == false { return .needsMicrophonePermission }
        if speechAuthorized == false { return .needsSpeechPermission }
        guard recognizerAvailable else { return .recognizerUnavailable }
        return nil
    }
}

/// Tracks the text this dictation session has inserted into the host app's
/// text field and converts each new partial transcript into the minimal
/// delete-backward + insert edit, so live results update in place instead of
/// duplicating.
public struct LiveTranscriptWriter: Equatable, Sendable {
    public struct Edit: Equatable, Sendable {
        public let deleteCount: Int
        public let insertText: String

        public init(deleteCount: Int, insertText: String) {
            self.deleteCount = deleteCount
            self.insertText = insertText
        }

        public var isNoOp: Bool { deleteCount == 0 && insertText.isEmpty }
    }

    public private(set) var insertedText = ""

    public init() {}

    /// Replace everything this session has inserted so far with `newText`.
    public mutating func edit(replacingWith newText: String) -> Edit {
        let current = Array(insertedText)
        let target = Array(newText)
        var shared = 0
        while shared < current.count, shared < target.count, current[shared] == target[shared] {
            shared += 1
        }
        let edit = Edit(
            deleteCount: current.count - shared,
            insertText: String(target[shared...])
        )
        insertedText = newText
        return edit
    }

    /// Final pass once recognition ends: clean fillers/punctuation and leave a
    /// trailing space so the user can keep dictating or typing naturally.
    public mutating func finishEdit(
        options: TranscriptCleanupOptions = .default,
        appendTrailingSpace: Bool = true
    ) -> Edit {
        var cleaned = TranscriptCleaner.clean(insertedText, options: options)
        if appendTrailingSpace, !cleaned.isEmpty {
            cleaned += " "
        }
        return edit(replacingWith: cleaned)
    }
}
