import Foundation

public enum VoiceAgentLimits {
    public static let emailRecipient = 254
    public static let emailSubject = 200
    public static let emailBody = 4_000
    public static let note = 8_000
    public static let message = 4_000
    public static let shortcutName = 100
}

public enum VoiceAgentPrimaryAction: Equatable, Sendable {
    case startConversation
    case finishTurn
    case wait
}

public enum VoiceAgentControlPolicy {
    public static func primaryAction(
        conversationActive: Bool,
        recording: Bool,
        busy: Bool
    ) -> VoiceAgentPrimaryAction {
        if conversationActive && recording {
            return .finishTurn
        }
        if conversationActive || busy {
            return .wait
        }
        return .startConversation
    }
}

public struct EmailAddress: Equatable, Sendable {
    public let value: String

    public init?(spoken input: String) {
        guard input.count <= VoiceAgentLimits.emailRecipient + 32 else { return nil }
        var candidate = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !candidate.contains(where: { $0.isNewline || $0.isASCII && $0.asciiValue! < 32 }) else { return nil }

        candidate = candidate.replacingOccurrences(
            of: #"\s+at\s+"#,
            with: "@",
            options: .regularExpression
        )
        candidate = candidate.replacingOccurrences(
            of: #"\s+dot\s+"#,
            with: ".",
            options: .regularExpression
        )
        candidate = candidate.replacingOccurrences(of: " ", with: "")
        candidate = candidate.trimmingCharacters(in: CharacterSet(charactersIn: ".,"))

        guard candidate.count <= VoiceAgentLimits.emailRecipient,
              !candidate.contains(where: { ",;:?&=/\\".contains($0) }),
              candidate.filter({ $0 == "@" }).count == 1
        else { return nil }

        let parts = candidate.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2,
              !parts[0].isEmpty,
              parts[0].count <= 64,
              parts[1].contains("."),
              !parts[1].hasPrefix("."),
              !parts[1].hasSuffix("."),
              !candidate.contains("..")
        else { return nil }

        let allowedLocal = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.!#$%&'*+-^_`{|}~")
        let allowedDomain = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-.")
        guard candidate.unicodeScalars.prefix(parts[0].count).allSatisfy(allowedLocal.contains),
              parts[1].unicodeScalars.allSatisfy(allowedDomain.contains),
              parts[1].split(separator: ".").allSatisfy({ !$0.isEmpty && !$0.hasPrefix("-") && !$0.hasSuffix("-") })
        else { return nil }

        value = candidate
    }
}

public struct EmailDraft: Equatable, Sendable {
    public let recipient: String
    public let subject: String
    public let body: String

    public init(recipient: String, subject: String, body: String) {
        self.recipient = recipient
        self.subject = subject
        self.body = body
    }
}

public enum VoiceAgentDestination: String, Equatable, Sendable {
    case gmailWeb
    case appSettings
    case maps
    case calendar
    case music
    case youtube
    case spotify
}

public enum VoiceAgentAction: Equatable, Sendable {
    case open(VoiceAgentDestination)
    case composeEmail(EmailDraft)
    case shareNote(String)
    case composeMessage(String)
    case runShortcut(String)

    public var reviewTitle: String {
        switch self {
        case .open(.gmailWeb): "Open Gmail"
        case .open(.appSettings): "Open Settings"
        case .open(.maps): "Open Maps"
        case .open(.calendar): "Open Calendar"
        case .open(.music): "Open Music"
        case .open(.youtube): "Open YouTube"
        case .open(.spotify): "Open Spotify"
        case .composeEmail: "Email draft"
        case .shareNote: "Note"
        case .composeMessage: "Message draft"
        case .runShortcut(let name): "Run \(name)"
        }
    }

    public static func validatedMessage(_ body: String) -> VoiceAgentAction? {
        guard let body = boundedText(body, limit: VoiceAgentLimits.message) else { return nil }
        return .composeMessage(body)
    }

    public static func validatedEmail(
        recipient: String,
        subject: String,
        body: String
    ) -> VoiceAgentAction? {
        guard let address = EmailAddress(spoken: recipient),
              let subject = boundedText(subject, limit: VoiceAgentLimits.emailSubject),
              let body = boundedText(body, limit: VoiceAgentLimits.emailBody)
        else { return nil }
        return .composeEmail(EmailDraft(recipient: address.value, subject: subject, body: body))
    }

    public static func validatedNote(_ body: String) -> VoiceAgentAction? {
        guard let body = boundedText(body, limit: VoiceAgentLimits.note) else { return nil }
        return .shareNote(body)
    }

    public static func validatedDestination(_ value: String) -> VoiceAgentAction? {
        let destination: VoiceAgentDestination
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "gmail": destination = .gmailWeb
        case "settings": destination = .appSettings
        case "maps": destination = .maps
        case "calendar": destination = .calendar
        case "music": destination = .music
        case "youtube": destination = .youtube
        case "spotify": destination = .spotify
        default: return nil
        }
        return .open(destination)
    }

    public static func validatedShortcut(_ name: String) -> VoiceAgentAction? {
        guard let name = boundedText(name, limit: VoiceAgentLimits.shortcutName),
              !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { return nil }
        return .runShortcut(name)
    }

    private static func boundedText(_ value: String, limit: Int) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.count <= limit,
              !trimmed.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\t"
              })
        else { return nil }
        return trimmed
    }
}

public enum VoiceAgentApprovalDecision: Equatable, Sendable {
    case confirm
    case cancel

    public init?(spoken input: String) {
        let normalized = input
            .lowercased()
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "’", with: "")
            .replacingOccurrences(of: #"[\p{P}\p{S}]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)

        let confirmations = ["confirm", "yes confirm", "yes open it", "open it", "go ahead", "do it"]
        let cancellations = ["cancel", "no cancel", "no dont open it", "dont open it", "never mind", "stop"]
        if confirmations.contains(normalized) {
            self = .confirm
        } else if cancellations.contains(normalized) {
            self = .cancel
        } else {
            return nil
        }
    }
}

public enum VoiceAgentStep: Equatable, Sendable {
    case idle
    case collectingEmailRecipient
    case collectingEmailSubject
    case collectingEmailBody
    case collectingNote
    case collectingMessage
    case awaitingConfirmation

    public var collectsProse: Bool {
        switch self {
        case .collectingEmailBody, .collectingNote, .collectingMessage:
            true
        case .idle, .collectingEmailRecipient, .collectingEmailSubject, .awaitingConfirmation:
            false
        }
    }
}

public struct VoiceAgentTurn: Equatable, Sendable {
    public let assistantMessage: String
    public let action: VoiceAgentAction?

    public init(assistantMessage: String, action: VoiceAgentAction? = nil) {
        self.assistantMessage = assistantMessage
        self.action = action
    }
}

public struct VoiceAgentSession: Sendable {
    private enum State: Equatable, Sendable {
        case idle
        case emailRecipient
        case emailSubject(recipient: String)
        case emailBody(recipient: String, subject: String)
        case note
        case message
        case confirmation(VoiceAgentAction)
    }

    private var state: State = .idle

    public init() {}

    public var step: VoiceAgentStep {
        switch state {
        case .idle: .idle
        case .emailRecipient: .collectingEmailRecipient
        case .emailSubject: .collectingEmailSubject
        case .emailBody: .collectingEmailBody
        case .note: .collectingNote
        case .message: .collectingMessage
        case .confirmation: .awaitingConfirmation
        }
    }

    public var pendingAction: VoiceAgentAction? {
        guard case .confirmation(let action) = state else { return nil }
        return action
    }

    public mutating func receive(_ input: String) -> VoiceAgentTurn {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            return VoiceAgentTurn(assistantMessage: "I didn't hear anything. Please try again.")
        }

        let intent = Self.normalizedIntent(value)
        if Self.isCancellation(intent) {
            return cancel()
        }
        if Self.isStartOver(intent) {
            state = .idle
            return VoiceAgentTurn(assistantMessage: "Okay, the draft is cleared. Tell me what you want to start again.")
        }

        if case .confirmation = state, Self.isConfirmation(intent) {
            return confirm()
        }

        switch state {
        case .idle:
            return begin(intent: intent)
        case .emailRecipient:
            return collectRecipient(value)
        case .emailSubject(let recipient):
            return collectSubject(value, recipient: recipient)
        case .emailBody(let recipient, let subject):
            return collectEmailBody(value, recipient: recipient, subject: subject)
        case .note:
            return collectNote(value)
        case .message:
            return collectMessage(value)
        case .confirmation:
            return VoiceAgentTurn(
                assistantMessage: "The action is still waiting for your approval. Say confirm, tap the action button, or cancel."
            )
        }
    }

    public mutating func confirm() -> VoiceAgentTurn {
        guard case .confirmation(let action) = state else {
            return VoiceAgentTurn(assistantMessage: "There is nothing waiting for confirmation.")
        }

        state = .idle
        let message: String
        switch action {
        case .composeEmail:
            message = "Opening your email draft. Review it there and choose Send when you are ready."
        case .shareNote:
            message = "Opening the share sheet. Choose Notes, then save it there."
        case .composeMessage:
            message = "Opening a message draft. Choose the recipient, review it, and tap Send when you are ready."
        case .runShortcut(let name):
            message = "Opening Shortcuts to run \(name)."
        case .open(.gmailWeb):
            message = "Opening Gmail in your browser."
        case .open(.appSettings):
            message = "Opening Settings."
        case .open(.maps):
            message = "Opening Maps."
        case .open(.calendar):
            message = "Opening Calendar."
        case .open(.music):
            message = "Opening Music."
        case .open(.youtube):
            message = "Opening YouTube."
        case .open(.spotify):
            message = "Opening Spotify."
        }
        return VoiceAgentTurn(assistantMessage: message, action: action)
    }

    public mutating func cancel() -> VoiceAgentTurn {
        let hadWork = state != .idle
        state = .idle
        return VoiceAgentTurn(
            assistantMessage: hadWork ? "Cancelled. Nothing was opened or shared." : "There is nothing to cancel."
        )
    }

    private mutating func begin(intent: String) -> VoiceAgentTurn {
        if Self.containsAny(intent, phrases: ["compose email", "compose an email", "write email", "write an email", "draft email", "draft an email", "send email", "send an email", "open compose"]) {
            state = .emailRecipient
            return VoiceAgentTurn(assistantMessage: "Who is the email for?")
        }
        if Self.containsAny(intent, phrases: ["send a message", "send message", "write a message", "write message", "text someone", "send a text", "text a message"]) {
            state = .message
            return VoiceAgentTurn(assistantMessage: "What should the message say?")
        }
        if intent.contains("note"),
           Self.containsAny(intent, phrases: ["are you able", "can you save", "save that", "save it", "in my notes app"]) {
            return VoiceAgentTurn(
                assistantMessage: "I can prepare the note and open the system share sheet. iOS still requires you to choose Notes and tap Save; I can't tap inside Notes for you."
            )
        }
        if intent.contains("note"), Self.containsAny(intent, phrases: ["create", "write", "start", "new", "open"]) {
            state = .note
            let message = intent.contains("open")
                ? "I can help create a note. What should it say?"
                : "What should the note say?"
            return VoiceAgentTurn(assistantMessage: message)
        }
        if intent.contains("gmail"), Self.containsAny(intent, phrases: ["open", "show", "go to"]) {
            let action = VoiceAgentAction.open(.gmailWeb)
            state = .confirmation(action)
            return VoiceAgentTurn(
                assistantMessage: "I can open Gmail in your browser. This will leave Hermes. Say confirm to continue."
            )
        }
        if intent.contains("settings"), Self.containsAny(intent, phrases: ["open", "show", "go to"]) {
            let action = VoiceAgentAction.open(.appSettings)
            state = .confirmation(action)
            return VoiceAgentTurn(
                assistantMessage: "I can open this app's Settings page. Say confirm to continue."
            )
        }
        let appDestinations: [(terms: [String], destination: VoiceAgentDestination)] = [
            (["maps", "map"], .maps),
            (["calendar"], .calendar),
            (["apple music", "music"], .music),
            (["youtube"], .youtube),
            (["spotify"], .spotify),
        ]
        if Self.containsAny(intent, phrases: ["open", "show", "go to", "launch"]),
           let match = appDestinations.first(where: { entry in
               entry.terms.contains(where: intent.contains)
           }) {
            let action = VoiceAgentAction.open(match.destination)
            state = .confirmation(action)
            return VoiceAgentTurn(
                assistantMessage: "I can \(action.reviewTitle.lowercased()). Say confirm to continue."
            )
        }
        if intent.hasPrefix("run shortcut ") {
            let name = String(intent.dropFirst("run shortcut ".count))
            if let action = VoiceAgentAction.validatedShortcut(name) {
                state = .confirmation(action)
                return VoiceAgentTurn(
                    assistantMessage: "I can run the \(name) shortcut. Say confirm to continue."
                )
            }
        }

        return VoiceAgentTurn(
            assistantMessage: "I can't do that safely yet. Try send a message, compose an email, create a note, or open a supported app."
        )
    }

    private mutating func collectRecipient(_ value: String) -> VoiceAgentTurn {
        guard let address = EmailAddress(spoken: value) else {
            return VoiceAgentTurn(
                assistantMessage: "Please say one valid email address, for example alex at example dot com."
            )
        }
        state = .emailSubject(recipient: address.value)
        return VoiceAgentTurn(assistantMessage: "What is the subject?")
    }

    private mutating func collectSubject(_ value: String, recipient: String) -> VoiceAgentTurn {
        guard value.count <= VoiceAgentLimits.emailSubject else {
            return VoiceAgentTurn(assistantMessage: "That subject is too long. Please keep it under 200 characters.")
        }
        state = .emailBody(recipient: recipient, subject: value)
        return VoiceAgentTurn(assistantMessage: "What should the email say?")
    }

    private mutating func collectEmailBody(_ value: String, recipient: String, subject: String) -> VoiceAgentTurn {
        guard value.count <= VoiceAgentLimits.emailBody else {
            return VoiceAgentTurn(assistantMessage: "That email body is too long. Please keep it under 4,000 characters.")
        }
        let action = VoiceAgentAction.composeEmail(
            EmailDraft(recipient: recipient, subject: subject, body: value)
        )
        state = .confirmation(action)
        return VoiceAgentTurn(
            assistantMessage: "Your email to \(recipient) is ready to review. Say confirm to open the draft, or cancel."
        )
    }

    private mutating func collectNote(_ value: String) -> VoiceAgentTurn {
        guard value.count <= VoiceAgentLimits.note else {
            return VoiceAgentTurn(assistantMessage: "That note is too long. Please keep it under 8,000 characters.")
        }
        let action = VoiceAgentAction.shareNote(value)
        state = .confirmation(action)
        return VoiceAgentTurn(
            assistantMessage: "Your note is ready. Say confirm to open the share sheet, then choose Notes."
        )
    }

    private mutating func collectMessage(_ value: String) -> VoiceAgentTurn {
        guard value.count <= VoiceAgentLimits.message else {
            return VoiceAgentTurn(assistantMessage: "That message is too long. Please keep it under 4,000 characters.")
        }
        let action = VoiceAgentAction.composeMessage(value)
        state = .confirmation(action)
        return VoiceAgentTurn(
            assistantMessage: "Your message is ready. Say confirm to choose the recipient and review it, or cancel."
        )
    }

    private static func normalizedIntent(_ value: String) -> String {
        value.lowercased()
            .replacingOccurrences(of: #"[^a-z0-9@]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    private static func containsAny(_ value: String, phrases: [String]) -> Bool {
        phrases.contains(where: value.contains)
    }

    private static func isCancellation(_ value: String) -> Bool {
        ["cancel", "never mind", "nevermind", "stop", "no", "no thanks", "do not do that", "don t do that"].contains(value)
    }

    private static func isStartOver(_ value: String) -> Bool {
        ["start over", "clear it", "clear draft", "restart"].contains(value)
    }

    private static func isConfirmation(_ value: String) -> Bool {
        ["confirm", "yes", "yes confirm", "yes please", "go ahead", "open it", "share it", "do it"].contains(value)
            || value.hasSuffix(" confirm")
    }
}

public enum VoiceAgentHandoff {
    public static func mailtoURL(for draft: EmailDraft) -> URL? {
        guard let address = EmailAddress(spoken: draft.recipient),
              address.value == draft.recipient,
              draft.subject.count <= VoiceAgentLimits.emailSubject,
              draft.body.count <= VoiceAgentLimits.emailBody
        else { return nil }

        var components = URLComponents()
        components.scheme = "mailto"
        components.path = draft.recipient
        components.queryItems = [
            URLQueryItem(name: "subject", value: draft.subject),
            URLQueryItem(name: "body", value: draft.body),
        ]
        return components.url
    }
}
