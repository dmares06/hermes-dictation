import Foundation
import Observation

/// Owns the in-app notes and the bridge to system Reminders, for the Notes
/// tab, the dictation card, and the voice agent alike.
@MainActor
@Observable
final class NotesController {
    private(set) var notes: [SavedNote] = []
    private(set) var reminders: [ReminderItem] = []
    private(set) var lastError: String?
    private(set) var remindersAuthorized = false
    /// Briefly true after a save so the UI can acknowledge it.
    private(set) var lastSavedNoteID: UUID?

    private let store: NoteStore
    private let reminderService: ReminderService

    init(store: NoteStore = NoteStore(), reminderService: ReminderService = ReminderService()) {
        self.store = store
        self.reminderService = reminderService
        notes = store.notes
        remindersAuthorized = reminderService.isAuthorized
    }

    // MARK: Notes

    @discardableResult
    func saveNote(_ body: String, title: String? = nil) -> SavedNote? {
        do {
            let note = try store.save(body: body, title: title)
            notes = store.notes
            lastSavedNoteID = note.id
            lastError = nil
            return note
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    func updateNote(id: UUID, body: String, title: String?) {
        do {
            try store.update(id: id, body: body, title: title)
            notes = store.notes
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func deleteNote(id: UUID) {
        do {
            try store.delete(id: id)
            notes = store.notes
        } catch {
            lastError = error.localizedDescription
        }
    }

    func search(_ query: String) -> [SavedNote] {
        store.search(query)
    }

    func clearSavedAcknowledgement() {
        lastSavedNoteID = nil
    }

    // MARK: Reminders

    func requestRemindersAccess() async {
        remindersAuthorized = await reminderService.requestAccess()
        if remindersAuthorized { await refreshReminders() }
    }

    func refreshReminders() async {
        remindersAuthorized = reminderService.isAuthorized
        reminders = await reminderService.upcoming()
    }

    @discardableResult
    func addReminder(_ draft: ReminderDraft) async -> ReminderItem? {
        do {
            let item = try await reminderService.create(draft)
            lastError = nil
            await refreshReminders()
            return item
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    func completeReminder(id: String) async {
        do {
            try reminderService.complete(id: id)
            await refreshReminders()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func deleteReminder(id: String) async {
        do {
            try reminderService.delete(id: id)
            await refreshReminders()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func dismissError() {
        lastError = nil
    }
}
