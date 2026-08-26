import SwiftUI

struct NotesView: View {
    enum Section: String, CaseIterable, Identifiable {
        case notes = "Notes"
        case reminders = "Reminders"
        var id: String { rawValue }
    }

    @Bindable var controller: NotesController
    @State private var section: Section = .notes
    @State private var query = ""
    @State private var editingNote: SavedNote?
    @State private var showsNewNote = false
    @State private var showsNewReminder = false

    var body: some View {
        NavigationStack {
            Group {
                switch section {
                case .notes: notesList
                case .reminders: remindersList
                }
            }
            .navigationTitle("Notes")
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("Section", selection: $section) {
                        ForEach(Section.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 240)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        if section == .notes { showsNewNote = true } else { showsNewReminder = true }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel(section == .notes ? "New note" : "New reminder")
                }
            }
            .sheet(isPresented: $showsNewNote) {
                NoteEditor(note: nil) { title, body in
                    controller.saveNote(body, title: title)
                }
            }
            .sheet(item: $editingNote) { note in
                NoteEditor(note: note) { title, body in
                    controller.updateNote(id: note.id, body: body, title: title)
                }
            }
            .sheet(isPresented: $showsNewReminder) {
                ReminderEditor { draft in
                    Task { await controller.addReminder(draft) }
                }
            }
            .alert("Something went wrong", isPresented: Binding(
                get: { controller.lastError != nil },
                set: { if !$0 { controller.dismissError() } }
            )) {
                Button("OK", role: .cancel) { controller.dismissError() }
            } message: {
                Text(controller.lastError ?? "")
            }
            .task { await controller.refreshReminders() }
        }
    }

    // MARK: Notes

    private var visibleNotes: [SavedNote] {
        query.isEmpty ? controller.notes : controller.search(query)
    }

    private var notesList: some View {
        List {
            if controller.notes.isEmpty {
                ContentUnavailableView(
                    "No notes yet",
                    systemImage: "note.text",
                    description: Text("Dictate on the Dictation tab and tap Save as note, tell Hermes to take a note, or tap + to type one.")
                )
                .listRowBackground(Color.clear)
            }
            ForEach(visibleNotes) { note in
                Button { editingNote = note } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(note.title).font(.headline).lineLimit(1)
                        Text(note.body).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                        Text(note.updatedAt, style: .relative).font(.caption).foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
                .swipeActions {
                    Button(role: .destructive) { controller.deleteNote(id: note.id) } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
        .searchable(text: $query, prompt: "Search notes")
    }

    // MARK: Reminders

    private var remindersList: some View {
        List {
            if !controller.remindersAuthorized {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Reminders access is off", systemImage: "bell.slash")
                        .font(.headline)
                    Text("Hermes adds reminders to the Reminders app so they alert you and sync everywhere.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Button("Allow Reminders") { Task { await controller.requestRemindersAccess() } }
                        .buttonStyle(.borderedProminent)
                }
                .padding(.vertical, 6)
            } else if controller.reminders.isEmpty {
                ContentUnavailableView(
                    "Nothing due",
                    systemImage: "checkmark.circle",
                    description: Text("Say “remind me to…” to Hermes, or tap + to add one.")
                )
                .listRowBackground(Color.clear)
            }
            ForEach(controller.reminders) { item in
                HStack(spacing: 12) {
                    Button {
                        Task { await controller.completeReminder(id: item.id) }
                    } label: {
                        Image(systemName: "circle").font(.title3).foregroundStyle(.mint)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Mark complete")
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.title)
                        if let due = item.dueDate {
                            Text(due, format: .dateTime.weekday(.abbreviated).month().day().hour().minute())
                                .font(.caption)
                                .foregroundStyle(due < Date() ? .red : .secondary)
                        }
                    }
                }
                .swipeActions {
                    Button(role: .destructive) {
                        Task { await controller.deleteReminder(id: item.id) }
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
        .refreshable { await controller.refreshReminders() }
    }
}

// MARK: - Editors

private struct NoteEditor: View {
    let note: SavedNote?
    let onSave: (String?, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var noteBody: String

    init(note: SavedNote?, onSave: @escaping (String?, String) -> Void) {
        self.note = note
        self.onSave = onSave
        _title = State(initialValue: note?.title ?? "")
        _noteBody = State(initialValue: note?.body ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Title (optional)", text: $title)
                TextEditor(text: $noteBody)
                    .frame(minHeight: 220)
                    .accessibilityLabel("Note text")
            }
            .navigationTitle(note == nil ? "New note" : "Edit note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(title.isEmpty ? nil : title, noteBody)
                        dismiss()
                    }
                    .disabled(noteBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

private struct ReminderEditor: View {
    let onAdd: (ReminderDraft) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var hasDate = false
    @State private var date = Date().addingTimeInterval(3600)

    /// Live preview of how the sentence will be understood, so "tomorrow at 9"
    /// typed in the title becomes the date rather than part of the text.
    private var parsed: ReminderDraft? { ReminderParser.parse(text) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Remind me to…", text: $text, axis: .vertical)
                } footer: {
                    if let parsed, let due = parsed.dueDate, !hasDate {
                        Text("Understood as “\(parsed.title)” on \(due.formatted(date: .abbreviated, time: .shortened)).")
                    }
                }
                Section {
                    Toggle("Set a specific time", isOn: $hasDate)
                    if hasDate {
                        DatePicker("When", selection: $date)
                    }
                }
            }
            .navigationTitle("New reminder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        guard let parsed else { return }
                        onAdd(ReminderDraft(title: parsed.title, dueDate: hasDate ? date : parsed.dueDate))
                        dismiss()
                    }
                    .disabled(parsed == nil)
                }
            }
        }
    }
}
