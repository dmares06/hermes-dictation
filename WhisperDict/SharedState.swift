import Foundation
import Observation

@Observable
final class SharedState {
    static let appGroupID = "group.com.dmares06.whisperdict"

    private let defaults: UserDefaults
    private let appearanceStore: AppearanceStore

    var modelSize: ModelSize {
        didSet { defaults.set(modelSize.rawValue, forKey: Keys.modelSize) }
    }
    var removeFillers: Bool {
        didSet { defaults.set(removeFillers, forKey: Keys.removeFillers) }
    }
    var autoPunctuate: Bool {
        didSet { defaults.set(autoPunctuate, forKey: Keys.autoPunctuate) }
    }
    var autoCapitalize: Bool {
        didSet { defaults.set(autoCapitalize, forKey: Keys.autoCapitalize) }
    }
    var welcomeDone: Bool {
        didSet { defaults.set(welcomeDone, forKey: Keys.welcomeDone) }
    }
    /// Phone number or iMessage address the compose sheet is pre-addressed to.
    /// Empty means the user picks a recipient each time.
    var defaultMessageRecipient: String {
        didSet { defaults.set(defaultMessageRecipient, forKey: Keys.defaultMessageRecipient) }
    }
    /// How long the app stays resident after use so the keyboard and Action
    /// Button can start a recording without bringing it forward.
    var listeningWindow: ListeningWindowDuration {
        didSet { defaults.set(listeningWindow.rawValue, forKey: Keys.listeningWindow) }
    }
    /// Realtime conversations play through the speaker by default: this is a
    /// phone you talk to, not one you hold to your ear.
    var agentUsesSpeaker: Bool {
        didSet { defaults.set(agentUsesSpeaker, forKey: Keys.agentUsesSpeaker) }
    }
    var emailDelivery: EmailDelivery {
        didSet { defaults.set(emailDelivery.rawValue, forKey: Keys.emailDelivery) }
    }
    var keyboardColor: AppearanceColor {
        didSet { appearanceStore.keyboardColor = keyboardColor }
    }
    var recordButtonColor: AppearanceColor {
        didSet { appearanceStore.recordButtonColor = recordButtonColor }
    }

    var modelFolderPath: String? {
        defaults.string(forKey: Keys.modelFolderPath)
    }

    /// `defaultMessageRecipient` as the compose sheet wants it: one entry, or
    /// none at all when the user has not set a recipient.
    var messageRecipients: [String] {
        MessageRecipients.normalize(defaultMessageRecipient)
    }

    init(defaults: UserDefaults? = UserDefaults(suiteName: SharedState.appGroupID)) {
        self.defaults = defaults ?? .standard
        self.appearanceStore = AppearanceStore(defaults: self.defaults)
        self.modelSize = ModelSize(rawValue: self.defaults.string(forKey: Keys.modelSize) ?? "small") ?? .small
        self.agentUsesSpeaker = self.defaults.object(forKey: Keys.agentUsesSpeaker) as? Bool ?? true
        self.removeFillers = self.defaults.object(forKey: Keys.removeFillers) as? Bool ?? true
        self.autoPunctuate = self.defaults.object(forKey: Keys.autoPunctuate) as? Bool ?? true
        self.autoCapitalize = self.defaults.object(forKey: Keys.autoCapitalize) as? Bool ?? true
        self.welcomeDone = self.defaults.bool(forKey: Keys.welcomeDone)
        self.defaultMessageRecipient = self.defaults.string(forKey: Keys.defaultMessageRecipient) ?? ""
        self.listeningWindow = ListeningWindowDuration(
            rawValue: self.defaults.string(forKey: Keys.listeningWindow) ?? ""
        ) ?? .fiveMinutes
        self.emailDelivery = EmailDelivery(
            rawValue: self.defaults.string(forKey: Keys.emailDelivery) ?? ""
        ) ?? .mailApp
        self.keyboardColor = self.appearanceStore.keyboardColor
        self.recordButtonColor = self.appearanceStore.recordButtonColor
    }

    func resetAppearance() {
        appearanceStore.reset()
        keyboardColor = .defaultKeyboard
        recordButtonColor = .defaultRecordButton
    }

    private enum Keys {
        static let modelSize = "modelSize"
        static let removeFillers = "removeFillers"
        static let autoPunctuate = "autoPunctuate"
        static let autoCapitalize = "autoCapitalize"
        static let welcomeDone = "welcomeDone"
        static let defaultMessageRecipient = "defaultMessageRecipient"
        static let listeningWindow = "listeningWindow"
        static let emailDelivery = "emailDelivery"
        static let agentUsesSpeaker = "agentUsesSpeaker"
        static let modelFolderPath = "modelFolderPath"
    }
}

enum ModelSize: String, CaseIterable, Identifiable {
    case tiny, base, small

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var detail: String {
        switch self {
        case .tiny: "Fastest · ~150 MB"
        case .base: "Balanced · ~300 MB"
        case .small: "Most accurate · ~600 MB"
        }
    }
}
