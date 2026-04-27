import SwiftUI
import SwiftData
import AMUXCore

#if os(iOS)

public struct IdeaSheet: View {
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
                "Ideas Live In The Ideas Tab",
                systemImage: IdeaUIPresentation.systemImage,
                description: Text("Use the dedicated Ideas tab for Supabase-backed idea management.")
            )
            .navigationTitle(IdeaUIPresentation.pluralTitle)
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

struct CreateIdeaSheet: View {
    @Environment(\.dismiss) private var dismiss

    @Bindable var ideaStore: IdeaStore
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
                    TextField("Capture an idea", text: $title, axis: .vertical)
                        .focused($titleFocused)
                        .lineLimit(2...5)
                }

                if let errorMessage = ideaStore.errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("New Idea")
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
            let ok = await ideaStore.createIdea(
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

struct EditIdeaSheet: View {
    @Environment(\.dismiss) private var dismiss

    @Bindable var ideaStore: IdeaStore
    let idea: IdeaRecord

    @State private var title: String
    @State private var description: String
    @State private var status: String
    @State private var isSaving = false

    init(ideaStore: IdeaStore, idea: IdeaRecord) {
        self.ideaStore = ideaStore
        self.idea = idea
        _title = State(initialValue: idea.title)
        _description = State(initialValue: idea.description)
        _status = State(initialValue: idea.status)
    }

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isSaving
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Title") {
                    TextField("Idea title", text: $title, axis: .vertical)
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

                if let errorMessage = ideaStore.errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Edit Idea")
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
            let ok = await ideaStore.updateIdea(
                ideaID: idea.id,
                title: title,
                description: description,
                status: status,
                workspaceID: idea.workspaceID
            )
            isSaving = false
            if ok {
                dismiss()
            }
        }
    }
}

struct IdeaRow: View {
    let item: IdeaRecord
    var creatorName: String? = nil

    init(item: IdeaRecord, creatorName: String? = nil) {
        self.item = item
        self.creatorName = creatorName
    }

    init(item: SessionIdea, creatorName: String? = nil) {
        self.item = IdeaRecord(
            id: item.ideaId,
            teamID: "",
            workspaceID: item.workspaceId,
            createdByActorID: item.createdBy,
            title: item.title,
            description: item.ideaDescription,
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
public struct IdeaSheet: View {
    public init(pairing: PairingManager, teamclawService: TeamclawService? = nil) {}

    public var body: some View {
        ContentUnavailableView("Ideas", systemImage: IdeaUIPresentation.systemImage)
    }
}

struct CreateIdeaSheet: View {
    @Bindable var ideaStore: IdeaStore
    let onCreated: () -> Void

    var body: some View {
        ContentUnavailableView("New Idea", systemImage: "plus")
    }
}

struct EditIdeaSheet: View {
    @Bindable var ideaStore: IdeaStore
    let idea: IdeaRecord

    var body: some View {
        ContentUnavailableView("Edit Idea", systemImage: "pencil")
    }
}

struct IdeaRow: View {
    let item: IdeaRecord
    var creatorName: String? = nil

    var body: some View {
        Text(item.displayTitle)
    }
}
#endif
