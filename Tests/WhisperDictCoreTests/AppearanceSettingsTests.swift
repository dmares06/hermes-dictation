import Foundation
import Testing
@testable import WhisperDictCore

struct AppearanceSettingsTests {
    @Test("Colors round-trip through canonical hex")
    func colorHexRoundTrip() {
        let color = AppearanceColor(red: 0.2, green: 0.4, blue: 0.8)

        #expect(color.hex == "#3366CC")
        #expect(AppearanceColor(hex: color.hex) == color)
    }

    @Test("Invalid stored colors use defaults")
    func invalidStoredColorsUseDefaults() {
        let suiteName = "AppearanceSettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("not-a-color", forKey: AppearanceStore.Keys.keyboardColor)
        defaults.set("#12", forKey: AppearanceStore.Keys.recordButtonColor)

        let store = AppearanceStore(defaults: defaults)

        #expect(store.keyboardColor == .defaultKeyboard)
        #expect(store.recordButtonColor == .defaultRecordButton)
    }

    @Test("Appearance choices persist independently")
    func appearanceChoicesPersistIndependently() {
        let suiteName = "AppearanceSettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = AppearanceStore(defaults: defaults)
        let keyboard = AppearanceColor(red: 0.55, green: 0.2, blue: 0.75)
        let record = AppearanceColor(red: 0.95, green: 0.3, blue: 0.15)

        store.keyboardColor = keyboard
        store.recordButtonColor = record

        let reloaded = AppearanceStore(defaults: defaults)
        #expect(reloaded.keyboardColor == keyboard)
        #expect(reloaded.recordButtonColor == record)
    }

    @Test("Contrast selection follows relative luminance", arguments: [
        (AppearanceColor(red: 1, green: 1, blue: 1), true),
        (AppearanceColor(red: 0, green: 0, blue: 0), false),
        (AppearanceColor.defaultRecordButton, false),
    ])
    func contrastSelection(color: AppearanceColor, expectsDarkText: Bool) {
        #expect(color.prefersDarkForeground == expectsDarkText)
    }
}
