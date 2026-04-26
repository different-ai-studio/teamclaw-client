import SwiftUI
import SwiftData
import AMUXCore

#if os(iOS)

public struct TaskSheet: View {
    @Environment(\.dismiss) private var dismiss

    let pairing: PairingManager
    let teamclawService: TeamclawService?

    public init(pairing: PairingManager, teamclawService: TeamclawService? = nil) {
        self.pairing = pairing
        self.teamclawService = teamclawService
    }

    public var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "Tasks Live In The Tasks Tab",
                systemImage: "checklist",
                description: Text("Use the dedicated Tasks tab for Supabase-backed task management.")
            )
            .navigationTitle("Tasks")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").font(.title3)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

struct CreateTaskSheet: View {
    @Environment(\.dismiss) private var dismiss

    @Bindable var taskStore: TaskStore
    let onCreated: () -> Void

    @State private var title = ""
    @State private var isSaving = false
    @FocusState private var titleFocused: Bool

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isSaving
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Title") {
                    TextField("Ship task", text: $title, axis: .vertical)
                        .focused($titleFocused)
                        .lineLimit(2...5)
                }

                if let errorMessage = taskStore.errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("New Task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { save() } label: {
                        if isSaving {
                            ProgressView()
                        } else {
                            Image(systemName: "checkmark")
                        }
                    }
                    .disabled(!canSave)
                }
            }
            .onAppear { titleFocused = true }
        }
    }

    private func save() {
        guard !isSaving, canSave else { return }
        isSaving = true
        Task {
            let ok = await taskStore.createTask(
                title: title,
                description: "",
                workspaceID: ""
            )
            isSaving = false
            if ok {
                onCreated()
                dismiss()
            }
        }
    }
}

struct EditTaskSheet: View {
    @Environment(\.dismiss) private var dismiss

    @Bindable var taskStore: TaskStore
    let task: TaskRecord

    @State private var title: String
    @State private var description: String
    @State private var status: String
    @State private var isSaving = false

    init(taskStore: TaskStore, task: TaskRecord) {
        self.taskStore = taskStore
        self.task = task
        _title = State(initialValue: task.title)
        _description = State(initialValue: task.description)
        _status = State(initialValue: task.status)
    }

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isSaving
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Title") {
                    TextField("Task title", text: $title, axis: .vertical)
                        .lineLimit(2...5)
                }

                Section("Description") {
                    TextField("Optional context", text: $description, axis: .vertical)
                        .lineLimit(4...8)
                }

                Section("Status") {
                    Picker("Status", selection: $status) {
                        Text("Open").tag("open")
                        Text("In Progress").tag("in_progress")
                        Text("Done").tag("done")
                    }
                    .pickerStyle(.segmented)
                }

                if let errorMessage = taskStore.errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Edit Task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        save()
                    } label: {
                        if isSaving {
                            ProgressView()
                        } else {
                            Image(systemName: "checkmark")
                        }
                    }
                    .disabled(!canSave)
                }
            }
        }
    }

    private func save() {
        guard !isSaving else { return }
        isSaving = true
        Task {
            let ok = await taskStore.updateTask(
                taskID: task.id,
                title: title,
                description: description,
                status: status,
                workspaceID: task.workspaceID
            )
            isSaving = false
            if ok {
                dismiss()
            }
        }
    }
}

struct TaskRow: View {
    let item: TaskRecord
    var creatorName: String? = nil

    init(item: TaskRecord, creatorName: String? = nil) {
        self.item = item
        self.creatorName = creatorName
    }

    init(item: SessionTask, creatorName: String? = nil) {
        self.item = TaskRecord(
            id: item.taskId,
            teamID: "",
            workspaceID: item.workspaceId,
            createdByActorID: item.createdBy,
            title: item.title,
            description: item.taskDescription,
            status: item.status,
            archived: item.archived,
            createdAt: item.createdAt,
            updatedAt: item.createdAt
        )
        self.creatorName = creatorName
    }

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(item.isDone ? .green : item.isInProgress ? Color.orange : Color.blue)
                .frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayTitle)
                    .font(.body)
                    .fontWeight(.medium)
                    .lineLimit(2)

                HStack(spacing: 4) {
                    Text(item.statusLabel)
                    if let creatorName, !creatorName.isEmpty {
                        Text("·").foregroundStyle(.tertiary)
                        Image(systemName: "person.crop.circle")
                            .font(.caption2)
                        Text(creatorName).lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            Text(item.createdAt, style: .relative)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
#else
public struct TaskSheet: View {
    public init(pairing: PairingManager, teamclawService: TeamclawService? = nil) {}

    public var body: some View {
        ContentUnavailableView("Tasks", systemImage: "checklist")
    }
}

struct CreateTaskSheet: View {
    @Bindable var taskStore: TaskStore
    let onCreated: () -> Void

    var body: some View {
        ContentUnavailableView("New Task", systemImage: "plus")
    }
}

struct EditTaskSheet: View {
    @Bindable var taskStore: TaskStore
    let task: TaskRecord

    var body: some View {
        ContentUnavailableView("Edit Task", systemImage: "pencil")
    }
}

struct TaskRow: View {
    let item: TaskRecord
    var creatorName: String? = nil

    var body: some View {
        Text(item.displayTitle)
    }
}
#endif
