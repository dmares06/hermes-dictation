import Foundation

public enum KeyboardKey: Hashable, Sendable {
    case character(String)
    case shift
    case delete
    case modeChange
    case globe
    case space
    case returnKey

    public var insertedText: String? {
        switch self {
        case .character(let value): value
        case .space: " "
        case .returnKey: "\n"
        case .shift, .delete, .modeChange, .globe: nil
        }
    }

    public func text(shifted: Bool) -> String? {
        guard let insertedText else { return nil }
        return shifted ? insertedText.uppercased() : insertedText
    }
}

public struct KeyboardLayout: Equatable, Sendable {
    public let rows: [[KeyboardKey]]

    public init(rows: [[KeyboardKey]]) {
        self.rows = rows
    }

    public static let alphabetic = KeyboardLayout(rows: [
        "qwertyuiop".map { .character(String($0)) },
        "asdfghjkl".map { .character(String($0)) },
        [.shift] + "zxcvbnm".map { .character(String($0)) } + [.delete],
        [.modeChange, .globe, .space, .returnKey],
    ])

    public static let numeric = KeyboardLayout(rows: [
        "1234567890".map { .character(String($0)) },
        ["-", "/", ":", ";", "(", ")", "$", "&", "@", "\""].map(KeyboardKey.character),
        [".", ",", "?", "!", "'"].map(KeyboardKey.character) + [.delete],
        [.modeChange, .globe, .space, .returnKey],
    ])
}
