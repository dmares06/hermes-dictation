import EventKit
import Foundation

/// Reminders go into the system Reminders app through EventKit, so they get
/// real alerts, sync, and Siri — everything an in-app list would lack.
struct ReminderItem: Identifiable, Equatable {
    let id: String
    let title: String
    let dueDate: Date?
    let isCompleted: Bool
}

@MainActor
final class ReminderService {
    enum ServiceError: LocalizedError {
        case accessDenied
        case noDefaultList

        var errorDescription: String? {
            switch self {
            case .accessDenied: "Reminders access is off. Enable it in Settings to add reminders."
            case .noDefaultList: "No Reminders list is available on this iPhone."
            }
        }
    }

    private let store = EKEventStore()

    /// Constructing the event store needs no actor; keeping init nonisolated
    /// lets the service be a default argument.
    nonisolated init() {}

    var authorization: EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: .reminder)
    }

    var isAuthorized: Bool {
        authorization == .fullAccess
    }

    func requestAccess() async -> Bool {
        if isAuthorized { return true }
        return (try? await store.requestFullAccessToReminders()) ?? false
    }

    @discardableResult
    func create(_ draft: ReminderDraft) async throws -> ReminderItem {
        guard await requestAccess() else { throw ServiceError.accessDenied }
        guard let calendar = store.defaultCalendarForNewReminders() else { throw ServiceError.noDefaultList }

        let reminder = EKReminder(eventStore: store)
        reminder.calendar = calendar
        reminder.title = draft.title
        if let due = draft.dueDate {
            reminder.dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute],
                from: due
            )
            reminder.addAlarm(EKAlarm(absoluteDate: due))
        }
        try store.save(reminder, commit: true)
        return ReminderItem(reminder)
    }

    /// Incomplete reminders across every list, soonest due first.
    func upcoming() async -> [ReminderItem] {
        guard isAuthorized else { return [] }
        let predicate = store.predicateForIncompleteReminders(
            withDueDateStarting: nil,
            ending: nil,
            calendars: nil
        )
        let reminders: [EKReminder] = await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { continuation.resume(returning: $0 ?? []) }
        }
        return reminders
            .map(ReminderItem.init)
            .sorted { lhs, rhs in
                switch (lhs.dueDate, rhs.dueDate) {
                case let (l?, r?): l < r
                case (nil, _?): false
                case (_?, nil): true
                case (nil, nil): lhs.title < rhs.title
                }
            }
    }

    func complete(id: String) throws {
        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else { return }
        reminder.isCompleted = true
        try store.save(reminder, commit: true)
    }

    func delete(id: String) throws {
        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else { return }
        try store.remove(reminder, commit: true)
    }
}

private extension ReminderItem {
    init(_ reminder: EKReminder) {
        id = reminder.calendarItemIdentifier
        title = reminder.title ?? "Reminder"
        dueDate = reminder.dueDateComponents.flatMap(Calendar.current.date(from:))
        isCompleted = reminder.isCompleted
    }
}
