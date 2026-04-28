import SwiftUI
import SwiftData
import AMUXCore

public struct IdeaDetailView: View {
    let ideaID: String
    @Bindable var ideaStore: IdeaStore
    let sessionViewModel: SessionListViewModel
    let teamclawService: TeamclawService?
    let mqtt: MQTTService
    let peerId: String
    @Binding var navigationPath: [String]

    @Environment(\.dismiss) private var dismiss
    @Query(filter: #Predicate<CachedActor> { $0.actorType == "member" },
           sort: \CachedActor.displayName)
    private var members: [CachedActor]
    @Query(sort: \Session.lastMessageAt, order: .reverse)
    private var allSessions: [Session]

    @State private var localTitle: String = ""
    @State private var localDescription: String = ""
    @State private var showNewSession = false
    @State private var showArchiveConfirm = false
    @State private var isArchiving = false
    @State private var didSeedLocals = false
    @FocusState private var titleFocused: Bool
    @FocusState private var descriptionFocused: Bool

    public init(
        ideaID: String,
        ideaStore: IdeaStore,
        sessionViewModel: SessionListViewModel,
        teamclawService: TeamclawService?,
        mqtt: MQTTService,
        peerId: String,
        navigationPath: Binding<[String]>
    ) {
        self.ideaID = ideaID
        self.ideaStore = ideaStore
        self.sessionViewModel = sessionViewModel
        self.teamclawService = teamclawService
        self.mqtt = mqtt
        self.peerId = peerId
        self._navigationPath = navigationPath
    }

    private var item: IdeaRecord? {
        ideaStore.idea(id: ideaID)
    }

    private var creatorLabel: String {
        guard let item else { return "—" }
        guard !item.createdByActorID.isEmpty else { return "—" }
        if let member = members.first(where: { $0.actorId == item.createdByActorID }) {
            return member.displayName
        }
        return "Unknown"
    }

    private var relatedSessions: [Session] {
        allSessions.filter { $0.ideaId == ideaID }
    }

    public var body: some View {
        Group {
            if let item {
                content(for: item)
            } else {
                ContentUnavailableView("Idea Not Found", systemImage: IdeaUIPresentation.systemImage)
            }
        }
        .onAppear { seedLocals() }
        .onChange(of: ideaID) { _, _ in didSeedLocals = false; seedLocals() }
    }

    @ViewBuilder
    private func content(for item: IdeaRecord) -> some View {
        List {
            Section("Title") {
                TextField("Title", text: $localTitle, axis: .vertical)
                    .lineLimit(1...3)
                    .focused($titleFocused)
                    .onSubmit { commitTitle(for: item) }
                    .onChange(of: titleFocused) { _, focused in
                        if !focused { commitTitle(for: item) }
                    }
            }

            Section("Status") {
                HStack(spacing: 8) {
                    statusPill("Open", value: "open", item: item)
                    statusPill("In Progress", value: "in_progress", item: item)
                    statusPill("Done", value: "done", item: item)
                }
                .padding(.vertical, 4)
            }

            Section("Description") {
                TextField("Add details…", text: $localDescription, axis: .vertical)
                    .lineLimit(3...10)
                    .focused($descriptionFocused)
                    .onChange(of: descriptionFocused) { _, focused in
                        if !focused { commitDescription(for: item) }
                    }
            }

            Section("Sessions") {
                if relatedSessions.isEmpty {
                    Text("No sessions linked yet.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(relatedSessions, id: \.sessionId) { session in
                        Button {
                            navigationPath.append("session:\(session.sessionId)")
                        } label: {
                            SessionLinkRow(session: session)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Section("Info") {
                LabeledContent("Created by", value: creatorLabel)
                LabeledContent("Created", value: item.createdAt.formatted(date: .abbreviated, time: .shortened))
            }

            Section {
                Button(role: .destructive) {
                    showArchiveConfirm = true
                } label: {
                    HStack {
                        Spacer()
                        if isArchiving {
                            ProgressView()
                        } else {
                            Text(item.archived ? "Unarchive" : "Archive")
                                .fontWeight(.medium)
                        }
                        Spacer()
                    }
                }
                .disabled(isArchiving)
            }

            if let err = ideaStore.errorMessage {
                Section {
                    Text(err).font(.footnote).foregroundStyle(.red)
                }
            }
        }
        .navigationTitle(IdeaUIPresentation.singularTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    titleFocused = false
                    descriptionFocused = false
                    showNewSession = true
                } label: {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.title3)
                        .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Start a session")
            }
        }
        .sheet(isPresented: $showNewSession) {
            NewSessionSheet(
                mqtt: mqtt,
                peerId: peerId,
                teamclawService: teamclawService,
                viewModel: sessionViewModel,
                preselectedIdeaId: item.id,
                onSessionCreated: { sessionKey in
                    showNewSession = false
                    navigationPath.append(sessionKey)
                }
            )
        }
        .confirmationDialog(
            item.archived ? "Unarchive this idea?" : "Archive this idea?",
            isPresented: $showArchiveConfirm,
            titleVisibility: .visible
        ) {
            Button(item.archived ? "Unarchive" : "Archive",
                   role: item.archived ? .none : .destructive) {
                performArchive(for: item)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(item.archived
                 ? "The idea will reappear in the main list."
                 : "Archived ideas are hidden from the main list but can be restored later.")
        }
    }

    private func seedLocals() {
        guard !didSeedLocals, let item else { return }
        localTitle = item.title
        localDescription = item.description
        didSeedLocals = true
    }

    private func commitTitle(for item: IdeaRecord) {
        let trimmed = localTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != item.title else {
            if trimmed.isEmpty { localTitle = item.title }
            return
        }
        Task {
            await ideaStore.updateIdea(
                ideaID: item.id,
                title: trimmed,
                description: item.description,
                status: item.status,
                workspaceID: item.workspaceID
            )
        }
    }

    private func commitDescription(for item: IdeaRecord) {
        guard localDescription != item.description else { return }
        Task {
            await ideaStore.updateIdea(
                ideaID: item.id,
                title: item.title,
                description: localDescription,
                status: item.status,
                workspaceID: item.workspaceID
            )
        }
    }

    private func performArchive(for item: IdeaRecord) {
        guard !isArchiving else { return }
        isArchiving = true
        Task {
            let ok = await ideaStore.setArchived(ideaID: item.id, archived: !item.archived)
            await MainActor.run {
                isArchiving = false
                if ok, !item.archived {
                    dismiss()
                }
            }
        }
    }

    private func statusPill(_ label: String, value: String, item: IdeaRecord) -> some View {
        let selected = item.status == value
        return Button {
            Task {
                await ideaStore.updateIdea(
                    ideaID: item.id,
                    title: item.title,
                    description: item.description,
                    status: value,
                    workspaceID: item.workspaceID
                )
            }
        } label: {
            Text(label)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .foregroundStyle(selected ? Color.white : Color.primary)
                .background(selected ? Color.accentColor : Color.clear)
                .clipShape(Capsule())
                .overlay(
                    Capsule().strokeBorder(selected ? Color.clear : Color.secondary.opacity(0.4), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}

private struct SessionLinkRow: View {
    let session: Session

    private var lastMessage: String {
        session.lastMessagePreview.isEmpty ? "No messages yet." : session.lastMessagePreview
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: session.primaryAgentId == nil ? "person.2.fill" : "cpu")
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title.isEmpty ? "Untitled Session" : session.title)
                    .font(.body)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Text(lastMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if let at = session.lastMessageAt ?? Optional(session.createdAt) {
                Text(at, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}
