import Foundation

/// The caller hears nothing while Hermes runs a tool, and a ten-second
/// silence reads as a dead line — in testing the user talked over it every
/// time. The narrator turns tool-start events into one short spoken line
/// per activity, spaced out so a busy turn is not a stream of interruptions.
public struct HermesProgressNarrator: Equatable {
    /// How long after one line before a different activity earns another.
    public static let holdOff: TimeInterval = 6

    private var lastLine: String?
    private var lastSpokenAt: Date?

    public init() {}

    /// The line to say for this tool starting now, or nil to stay quiet.
    public mutating func narration(forTool name: String, at now: Date) -> String? {
        guard let line = Self.line(forTool: name) else { return nil }
        if let lastSpokenAt {
            guard now.timeIntervalSince(lastSpokenAt) >= Self.holdOff, line != lastLine else { return nil }
        }
        lastLine = line
        lastSpokenAt = now
        return line
    }

    public mutating func reset() {
        lastLine = nil
        lastSpokenAt = nil
    }

    /// What to say for a tool. Nil for Hermes's own housekeeping — finding
    /// a tool, reading a skill, updating a to-do — which is quick and would
    /// only be noise.
    public static func line(forTool name: String) -> String? {
        if Self.silentTools.contains(name) || name.hasPrefix("skill") || name.hasPrefix("todo") || name.hasPrefix("memory") {
            return nil
        }
        if name.contains("flights") { return "Checking flights now." }
        if name.hasPrefix("web_search") { return "Searching the web now." }
        if name.hasPrefix("web_") { return "Reading a page." }
        if name.hasPrefix("browser") { return "Opening the browser." }
        if name == "session_search" || name.hasPrefix("brv_") { return "Checking my memory." }
        return "Working on it."
    }

    private static let silentTools: Set<String> = ["tool_search", "tool_describe", "tool_call"]
}
