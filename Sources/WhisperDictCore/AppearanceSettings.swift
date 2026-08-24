import Foundation

public enum KeyboardRecorderAction: Equatable, Sendable {
    case requestStop
    case showTranscribing
    case showFailure
    case showActionButtonGuidance
}

public enum KeyboardHandoffGuidance {
    public static func idleMessage(hasFullAccess: Bool) -> String {
        hasFullAccess
            ? "Press your iPhone Action Button to record and insert"
            : "Turn on Full Access for WhisperDict in Settings to insert recordings here"
    }

    public static func recorderAction(for phase: BackgroundDictationPhase) -> KeyboardRecorderAction {
        switch phase {
        case .recording: .requestStop
        case .transcribing: .showTranscribing
        case .failed: .showFailure
        case .idle, .ready: .showActionButtonGuidance
        }
    }

    public static func recorderButtonTitle(for phase: BackgroundDictationPhase) -> String {
        switch phase {
        case .recording: "Stop"
        case .transcribing: "Working"
        case .idle, .ready, .failed: "Action Button"
        }
    }
}

public struct AppearanceColor: Equatable, Sendable {
    public static let defaultKeyboard = AppearanceColor(hex: "#5AC8FA")!
    public static let defaultRecordButton = AppearanceColor(hex: "#00C7BE")!

    public let red: Double
    public let green: Double
    public let blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = Double(Self.byte(red)) / 255
        self.green = Double(Self.byte(green)) / 255
        self.blue = Double(Self.byte(blue)) / 255
    }

    public init?(hex: String) {
        let value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = value.hasPrefix("#") ? String(value.dropFirst()) : value
        guard digits.count == 6, let packed = UInt32(digits, radix: 16) else { return nil }
        self.init(
            red: Double((packed >> 16) & 0xFF) / 255,
            green: Double((packed >> 8) & 0xFF) / 255,
            blue: Double(packed & 0xFF) / 255
        )
    }

    public var hex: String {
        String(
            format: "#%02X%02X%02X",
            Self.byte(red),
            Self.byte(green),
            Self.byte(blue)
        )
    }

    public var prefersDarkForeground: Bool {
        (red * 0.299 + green * 0.587 + blue * 0.114) > 0.6
    }

    private static func clamp(_ component: Double) -> Double {
        min(max(component, 0), 1)
    }

    private static func byte(_ component: Double) -> Int {
        Int((clamp(component) * 255).rounded())
    }
}

public final class AppearanceStore {
    public enum Keys {
        public static let keyboardColor = "keyboardColor"
        public static let recordButtonColor = "recordButtonColor"
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults? = UserDefaults(suiteName: TranscriptStore.appGroupID)) {
        self.defaults = defaults ?? .standard
    }

    public var keyboardColor: AppearanceColor {
        get { storedColor(forKey: Keys.keyboardColor) ?? .defaultKeyboard }
        set { defaults.set(newValue.hex, forKey: Keys.keyboardColor) }
    }

    public var recordButtonColor: AppearanceColor {
        get { storedColor(forKey: Keys.recordButtonColor) ?? .defaultRecordButton }
        set { defaults.set(newValue.hex, forKey: Keys.recordButtonColor) }
    }

    public func reset() {
        defaults.removeObject(forKey: Keys.keyboardColor)
        defaults.removeObject(forKey: Keys.recordButtonColor)
    }

    private func storedColor(forKey key: String) -> AppearanceColor? {
        defaults.string(forKey: key).flatMap(AppearanceColor.init(hex:))
    }
}

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UIKit

extension Color {
    init(appearanceColor: AppearanceColor) {
        self.init(
            red: appearanceColor.red,
            green: appearanceColor.green,
            blue: appearanceColor.blue
        )
    }

    var appearanceColor: AppearanceColor? {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard UIColor(self).getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return nil
        }
        return AppearanceColor(red: red, green: green, blue: blue)
    }
}
#endif
