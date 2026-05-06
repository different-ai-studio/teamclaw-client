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
    var creator: CachedActor?
    var workspaceName: String?

    init(item: IdeaRecord, creator: CachedActor? = nil, workspaceName: String? = nil) {
        self.item = item
        self.creator = creator
        self.workspaceName = workspaceName
    }

    init(item: SessionIdea, creator: CachedActor? = nil, workspaceName: String? = nil) {
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
        self.creator = creator
        self.workspaceName = workspaceName
    }

    private var pillForeground: Color {
        if item.isDone       { return Color(red: 0x1B/255, green: 0x7A/255, blue: 0x3D/255) }
        if item.isInProgress { return Color(red: 0xA2/255, green: 0x58/255, blue: 0x0B/255) }
        return Color(red: 0x00/255, green: 0x64/255, blue: 0xD8/255)
    }

    private var pillBackground: Color {
        if item.isDone       { return Color(red: 0x34/255, green: 0xC7/255, blue: 0x59/255).opacity(0.10) }
        if item.isInProgress { return Color(red: 0xFF/255, green: 0x95/255, blue: 0x00/255).opacity(0.12) }
        return Color(red: 0x00/255, green: 0x7A/255, blue: 0xFF/255).opacity(0.10)
    }

    private var creatorInitial: String {
        guard let name = creator?.displayName, let first = name.first else { return "·" }
        return String(first).uppercased()
    }

    /// Deterministic placeholder while a real submissions aggregate lands —
    /// stable per idea so the UI doesn't reshuffle between rebuilds. The
    /// distribution leans toward 0/1 so the chip stays sparse.
    private var mockSubmissionCount: Int {
        let buckets = [0, 0, 0, 1, 1, 2, 3, 4]
        let h = abs(item.id.unicodeScalars.reduce(0) { $0 &+ Int($1.value) })
        return buckets[h % buckets.count]
    }

    /// Mirrors the human-avatar palette used in the Actors list so the same
    /// teammate carries the same color across surfaces.
    private var creatorAvatarColor: Color {
        guard let id = creator?.actorId, !id.isEmpty else { return .secondary }
        let palette: [Color] = [
            Color(red: 0x00/255, green: 0x7A/255, blue: 0xFF/255),
            Color(red: 0x58/255, green: 0x56/255, blue: 0xD6/255),
            Color(red: 0xFF/255, green: 0x95/255, blue: 0x00/255),
            Color(red: 0x34/255, green: 0xC7/255, blue: 0x59/255),
            Color(red: 0xFF/255, green: 0x2D/255, blue: 0x55/255),
            Color(red: 0x5A/255, green: 0xC8/255, blue: 0xFA/255),
            Color(red: 0x5A/255, green: 0xC8/255, blue: 0xFA/255),
        ]
        let hash = id.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return palette[abs(hash) % palette.count]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                statusPill
                if let name = workspaceName, !name.isEmpty {
                    Text(name)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if mockSubmissionCount > 0 {
                    submissionCountChip
                }
            }

            Text(item.displayTitle)
                .font(.body)
                .fontWeight(.semibold)
                .foregroundStyle(item.isDone ? .secondary : .primary)
                .strikethrough(item.isDone, color: .secondary)
                .lineLimit(2)

            if !item.description.isEmpty, item.description != item.displayTitle {
                Text(item.description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            if let creator, !creator.displayName.isEmpty {
                creatorFooter(creator)
            }
        }
        .padding(.vertical, 6)
    }

    private var statusPill: some View {
        HStack(spacing: 5) {
            statusGlyph
            Text(item.statusLabel.uppercased())
                .font(.system(size: 10.5, weight: .bold))
                .tracking(0.3)
        }
        .foregroundStyle(pillForeground)
        .padding(.horizontal, 9)
        .frame(height: 22)
        .background(Capsule().fill(pillBackground))
    }

    @ViewBuilder
    private var statusGlyph: some View {
        if item.isDone {
            Image(systemName: "checkmark")
                .font(.system(size: 9, weight: .heavy))
        } else if item.isInProgress {
            ZStack {
                Circle()
                    .stroke(pillForeground.opacity(0.35), lineWidth: 1.4)
                Circle()
                    .trim(from: 0, to: 0.6)
                    .stroke(pillForeground, style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 8, height: 8)
        } else {
            Circle()
                .strokeBorder(pillForeground, lineWidth: 1.5)
                .frame(width: 8, height: 8)
        }
    }

    private var submissionCountChip: some View {
        HStack(spacing: 3) {
            Image(systemName: "tray.full")
                .font(.system(size: 10, weight: .medium))
            Text("\(mockSubmissionCount)")
                .font(.caption)
                .fontWeight(.medium)
                .monospacedDigit()
        }
        .foregroundStyle(.secondary)
    }

    private func creatorFooter(_ creator: CachedActor) -> some View {
        HStack(spacing: 6) {
            Text("Created by")
                .font(.caption)
                .foregroundStyle(.secondary)
            ZStack {
                Circle().fill(creatorAvatarColor)
                Text(creatorInitial)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 18, height: 18)
            Text(creator.displayName)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .padding(.top, 2)
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
