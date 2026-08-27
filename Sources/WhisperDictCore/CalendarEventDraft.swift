import Foundation

/// A calendar event Hermes has prepared but not yet written.
///
/// Events go into the system calendar through EventKit, the same way
/// reminders do, so they land in whatever accounts the iPhone already syncs
/// and show up in Calendar, on the Lock Screen, and in Siri.
public struct CalendarEventDraft: Equatable, Sendable {
    public static let maximumTitleLength = 200
    public static let maximumLocationLength = 200
    public static let maximumNotesLength = 2_000
    /// What "put it in my calendar at three" means when no end is given.
    public static let defaultDuration: TimeInterval = 60 * 60
    /// A spoken event that claims to run longer than a week is a
    /// misheard date, not a plan.
    public static let maximumDuration: TimeInterval = 60 * 60 * 24 * 7

    public let title: String
    public let start: Date
    public let end: Date
    public let isAllDay: Bool
    public let location: String?
    public let notes: String?

    public init(
        title: String,
        start: Date,
        end: Date,
        isAllDay: Bool = false,
        location: String? = nil,
        notes: String? = nil
    ) {
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.location = location
        self.notes = notes
    }

    public var duration: TimeInterval { end.timeIntervalSince(start) }

    /// A one-line description for the confirmation card and the spoken
    /// read-back, in the user's own locale.
    public func summary(calendar: Calendar = .current) -> String {
        let dayFormat = Date.FormatStyle(date: .abbreviated, time: .omitted)
        let timeFormat = Date.FormatStyle(date: .omitted, time: .shortened)
        if isAllDay {
            return "\(title) — all day \(start.formatted(dayFormat))"
        }
        let day = start.formatted(dayFormat)
        let from = start.formatted(timeFormat)
        let to = end.formatted(timeFormat)
        if calendar.isDate(start, inSameDayAs: end) {
            return "\(title) — \(day), \(from) to \(to)"
        }
        return "\(title) — \(day) \(from) to \(end.formatted(dayFormat)) \(to)"
    }
}
