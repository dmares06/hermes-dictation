import Foundation

public struct KeyboardTextEdit: Equatable, Sendable {
    public let deleteBackwardCount: Int
    public let insertedText: String

    public init(deleteBackwardCount: Int, insertedText: String) {
        self.deleteBackwardCount = deleteBackwardCount
        self.insertedText = insertedText
    }
}

public enum KeyboardTextProcessor {
    private static let attachingPunctuation = CharacterSet(charactersIn: ".,!?;:")
    private static let sentenceEndings = CharacterSet(charactersIn: ".!?")

    public static func edit(
        for insertedText: String,
        contextBeforeInput: String?
    ) -> KeyboardTextEdit {
        let context = contextBeforeInput ?? ""

        if isAttachingPunctuation(insertedText) {
            return KeyboardTextEdit(
                deleteBackwardCount: context.reversed().prefix { $0 == " " }.count,
                insertedText: insertedText
            )
        }

        guard insertedText == " ", context.hasSuffix(" "), let previous = context.dropLast().last else {
            return KeyboardTextEdit(deleteBackwardCount: 0, insertedText: insertedText)
        }

        if isSentenceEnding(previous) {
            return KeyboardTextEdit(deleteBackwardCount: 0, insertedText: "")
        }

        if previous.isLetter || previous.isNumber || ")]\"'".contains(previous) {
            return KeyboardTextEdit(deleteBackwardCount: 1, insertedText: ". ")
        }

        return KeyboardTextEdit(deleteBackwardCount: 0, insertedText: insertedText)
    }

    private static func isAttachingPunctuation(_ text: String) -> Bool {
        guard text.count == 1, let scalar = text.unicodeScalars.first else { return false }
        return attachingPunctuation.contains(scalar)
    }

    private static func isSentenceEnding(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        return sentenceEndings.contains(scalar)
    }
}
