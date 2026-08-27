import EventKit
import Foundation

/// One event on the user's calendar, flattened for the agent and the UI.
struct CalendarEventItem: Identifiable, Equatable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let location: String?
    let calendarName: String
}

/// Calendar events go into the system calendar through EventKit, for the same
/// reason reminders do: they land in the accounts the iPhone already syncs, so
/// they show up in Calendar, on the Lock Screen, in Siri, and on every other
/// device — none of which an app-private list would do.
@MainActor
final class CalendarService {
    enum ServiceError: LocalizedError {
        case accessDenied
        case noWritableCalendar

        var errorDescription: String? {
            switch self {
            case .accessDenied:
                "Calendar access is off. Enable it in Settings so Hermes can add events."
            case .noWritableCalendar:
                "No calendar on this iPhone accepts new events."
            }
        }
    }

    private let store = EKEventStore()

    /// Constructing the event store needs no actor; keeping init nonisolated
    /// lets the service be a default argument.
    nonisolated init() {}

    var authorization: EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: .event)
    }

    var isAuthorized: Bool { authorization == .fullAccess }

    func requestAccess() async -> Bool {
        if isAuthorized { return true }
        return (try? await store.requestFullAccessToEvents()) ?? false
    }

    @discardableResult
    func create(_ draft: CalendarEventDraft) async throws -> CalendarEventItem {
        guard await requestAccess() else { throw ServiceError.accessDenied }
        guard let calendar = store.defaultCalendarForNewEvents, calendar.allowsContentModifications
        else { throw ServiceError.noWritableCalendar }

        let event = EKEvent(eventStore: store)
        event.calendar = calendar
        event.title = draft.title
        event.startDate = draft.start
        event.endDate = draft.end
        event.isAllDay = draft.isAllDay
        event.location = draft.location
        event.notes = draft.notes
        // A timed event nobody is reminded about is one nobody attends.
        if !draft.isAllDay {
            event.addAlarm(EKAlarm(relativeOffset: -10 * 60))
        }
        try store.save(event, span: .thisEvent, commit: true)
        return CalendarEventItem(event)
    }

    /// Events starting between now and `days` from now, soonest first.
    func upcoming(days: Int = 7, limit: Int = 10, now: Date = Date()) async -> [CalendarEventItem] {
        guard isAuthorized else { return [] }
        let span = max(1, min(days, 60))
        guard let end = Calendar.current.date(byAdding: .day, value: span, to: now) else { return [] }
        let predicate = store.predicateForEvents(withStart: now, end: end, calendars: nil)
        return store.events(matching: predicate)
            .map(CalendarEventItem.init)
            .sorted { $0.start < $1.start }
            .prefix(max(1, limit))
            .map { $0 }
    }
}

private extension CalendarEventItem {
    init(_ event: EKEvent) {
        id = event.eventIdentifier ?? UUID().uuidString
        title = event.title ?? "Event"
        start = event.startDate
        end = event.endDate
        isAllDay = event.isAllDay
        location = event.location
        calendarName = event.calendar?.title ?? "Calendar"
    }
}
