import SwiftUI
import SwiftData
import AMUXCore

#if os(iOS)

public struct MemberListContent: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \CachedActor.displayName) private var actors: [CachedActor]
    @State private var searchText = ""

    let store: ActorStore
    let pairing: PairingManager
    let mqtt: MQTTService
    let sessionViewModel: SessionListViewModel

    public init(store: ActorStore, pairing: PairingManager, mqtt: MQTTService, sessionViewModel: SessionListViewModel) {
        self.store = store
        self.pairing = pairing
        self.mqtt = mqtt
        self.sessionViewModel = sessionViewModel
    }

    private var filtered: [CachedActor] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return actors }
        let norm = q.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        return actors.filter { a in
            [a.displayName, a.roleLabel, a.agentKind ?? "", a.actorId]
                .joined(separator: " ")
                .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
                .contains(norm)
        }
    }

    public var body: some View {
        Group {
            if actors.isEmpty {
                ContentUnavailableView("No Actors Yet", systemImage: "person.2",
                                       description: Text("Invite teammates or agents to see them here."))
            } else if filtered.isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else {
                List {
                    ForEach(filtered, id: \.actorId) { a in
                        NavigationLink {
                            ActorDetailView(
                                actor: a,
                                pairing: pairing,
                                mqtt: mqtt,
                                sessionViewModel: sessionViewModel,
                                store: store
                            )
                        } label: {
                            ActorRow(actor: a)
                        }
                    }
                }
            }
        }
        .searchable(text: $searchText, prompt: "Search actors")
        .task { await store.reload(); await store.heartbeat() }
        .refreshable { await store.reload() }
    }
}

private struct ActorRow: View {
    let actor: CachedActor
    var body: some View {
        HStack {
            Circle().fill(actor.isOnline ? Color.green : Color.secondary.opacity(0.4))
                    .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(actor.displayName).font(.body)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(actor.isOnline ? "Online" : "Offline")
                .font(.caption)
                .foregroundStyle(actor.isOnline ? .green : .secondary)
            if actor.isOwner {
                Image(systemName: "crown.fill").foregroundStyle(.orange).font(.caption)
            }
        }
    }
    private var subtitle: String {
        if actor.isMember { return actor.roleLabel }
        let kind = actor.agentKind?.capitalized ?? "Agent"
        let status = actor.agentStatus ?? ""
        return status.isEmpty ? kind : "\(kind) · \(status)"
    }
}

private struct ActorDetailView: View {
    @Query(sort: \CachedActor.displayName) private var cachedActors: [CachedActor]
    let actor: CachedActor
    let pairing: PairingManager
    let mqtt: MQTTService
    let sessionViewModel: SessionListViewModel
    let store: ActorStore
    @Environment(\.dismiss) private var dismiss
    @State private var authorizedHumansStore: AgentAuthorizedHumansStore?
    @State private var workspaceStore: WorkspaceStore?
    @State private var newWorkspacePath = ""
    @State private var workspaceErrorMessage: String?
    @State private var isAddingWorkspace = false
    @State private var isCreatingInvite = false
    @State private var inviteErrorMessage: String?
    @State private var createdInvite: InviteCreated?
    @State private var showInviteSheet = false
    @State private var showAddAuthorizedMembersSheet = false
    @State private var isGrantingAuthorizedMembers = false
    @State private var showDeleteConfirm = false
    @State private var isDeleting = false
    @State private var deleteErrorMessage: String?

    private var daemonDeviceID: String {
        pairing.deviceId.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var peerID: String {
        "ios-\(actor.actorId.prefix(8))"
    }

    private var canManageWorkspaces: Bool {
        !daemonDeviceID.isEmpty &&
        mqtt.connectionState == .connected
    }

    private var availableAuthorizedMemberCandidates: [CachedActor] {
        let authorizedIDs = Set(authorizedHumansStore?.humans.map(\.id) ?? [])
        return cachedActors.filter { candidate in
            candidate.teamId == actor.teamId &&
            candidate.isMember &&
            !authorizedIDs.contains(candidate.actorId)
        }
    }

    var body: some View {
        List {
            Section("Info") {
                LabeledContent("Name", value: actor.displayName)
                LabeledContent("Kind", value: actor.isMember ? "Human" : "Agent")
                if actor.isMember {
                    LabeledContent("Role",   value: actor.roleLabel)
                    LabeledContent("Status", value: actor.memberStatus?.capitalized ?? "—")
                } else {
                    LabeledContent("Agent kind", value: actor.agentKind ?? "—")
                    LabeledContent("Status",     value: actor.agentStatus?.capitalized ?? "—")
                }
                LabeledContent("Joined",
                               value: actor.createdAt.formatted(date: .abbreviated, time: .shortened))
            }
            if !actor.isMember, let store = authorizedHumansStore {
                Section("Authorized Members") {
                    if store.humans.isEmpty && !store.isLoading {
                        Text("No members authorized yet.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(store.humans) { human in
                            AuthorizedHumanRow(human: human)
                        }
                    }

                    if store.canManage {
                        Button {
                            showAddAuthorizedMembersSheet = true
                        } label: {
                            HStack {
                                Label("Add Member", systemImage: "person.badge.plus")
                                Spacer()
                                if isGrantingAuthorizedMembers {
                                    ProgressView()
                                        .controlSize(.small)
                                }
                            }
                        }
                        .disabled(isGrantingAuthorizedMembers || availableAuthorizedMemberCandidates.isEmpty)

                        if availableAuthorizedMemberCandidates.isEmpty {
                            Text("All team members are already authorized.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Added members get Prompt access.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let err = store.errorMessage {
                        Text(err).font(.footnote).foregroundStyle(.red)
                    }
                }
            }
            if actor.isAgent {
                Section("Workspaces") {
                    if let workspaceStore, workspaceStore.isLoading && workspaceStore.workspaces.isEmpty {
                        ProgressView("Loading workspaces…")
                    } else if let workspaceStore {
                        if workspaceStore.workspaces.isEmpty {
                            Text("No workspaces yet.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(workspaceStore.workspaces) { workspace in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(workspace.displayName)
                                        .font(.body)
                                    Text(workspace.path)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                    } else {
                        Text("Workspace list unavailable.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    if let workspaceStore, let workspaceLoadError = workspaceStore.errorMessage {
                        Text(workspaceLoadError)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }

                    HStack(spacing: 8) {
                        TextField("/Users/me/project", text: $newWorkspacePath)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()

                        Button {
                            addWorkspace()
                        } label: {
                            Image(systemName: "plus.circle.fill")
                                .font(.title3)
                                .symbolRenderingMode(.hierarchical)
                        }
                        .buttonStyle(.plain)
                        .disabled(
                            !canManageWorkspaces ||
                            isAddingWorkspace ||
                            newWorkspacePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        )
                    }

                    if daemonDeviceID.isEmpty {
                        Text("Daemon routing is unavailable. Set the daemon device ID in Settings before adding workspaces.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else if mqtt.connectionState != .connected {
                        Text("Connect to the daemon before adding workspaces.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    if let workspaceErrorMessage {
                        Text(workspaceErrorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            Section("ID") {
                Text(actor.actorId).font(.caption)
                    .foregroundStyle(.secondary).textSelection(.enabled)
            }
            Section {
                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    HStack {
                        Spacer()
                        if isDeleting {
                            ProgressView()
                        } else {
                            Text(actor.isMember ? "Remove Member" : "Remove Agent")
                                .fontWeight(.medium)
                        }
                        Spacer()
                    }
                }
                .disabled(isDeleting)
                if let inviteErrorMessage {
                    Text(inviteErrorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                if let deleteErrorMessage {
                    Text(deleteErrorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle(actor.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if actor.isAgent {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        createInvite()
                    } label: {
                        if isCreatingInvite {
                            ProgressView()
                        } else {
                            Image(systemName: "paperplane")
                        }
                    }
                    .disabled(isCreatingInvite || isDeleting)
                }
            }
        }
        .confirmationDialog(
            actor.isMember ? "Remove \(actor.displayName) from the team?" : "Remove agent \(actor.displayName)?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) { performDelete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(actor.isMember
                 ? "They will lose access to all of this team's tasks and sessions."
                 : "The agent's Supabase identity, daemon credentials, and member authorizations will be deleted.")
        }
        .task {
            guard !actor.isMember, authorizedHumansStore == nil else { return }
            if let repo = try? SupabaseAgentAccessRepository() {
                let store = AgentAuthorizedHumansStore(agentID: actor.actorId, teamID: actor.teamId, repository: repo)
                authorizedHumansStore = store
                await store.reload()
            }
        }
        .task {
            guard actor.isAgent, workspaceStore == nil else { return }
            if let repo = try? SupabaseWorkspaceRepository() {
                let store = WorkspaceStore(teamID: actor.teamId, repository: repo)
                workspaceStore = store
                await store.reload(agentID: actor.actorId)
            }
        }
        .sheet(isPresented: $showInviteSheet) {
            if let createdInvite {
                InviteShareSheet(invite: createdInvite)
            }
        }
        .sheet(isPresented: $showAddAuthorizedMembersSheet) {
            AuthorizedMemberPickerSheet(candidates: availableAuthorizedMemberCandidates) { selectedMembers in
                grantAuthorizedMembers(selectedMembers)
            }
        }
        .refreshable {
            await authorizedHumansStore?.reload()
            await workspaceStore?.reload(agentID: actor.actorId)
        }
    }

    private func performDelete() {
        guard !isDeleting else { return }
        isDeleting = true
        deleteErrorMessage = nil
        Task {
            let ok = await store.removeActor(actorID: actor.actorId)
            await MainActor.run {
                isDeleting = false
                if ok {
                    dismiss()
                } else {
                    deleteErrorMessage = store.errorMessage ?? "Delete failed."
                }
            }
        }
    }

    private func createInvite() {
        guard actor.isAgent, !isCreatingInvite else { return }
        isCreatingInvite = true
        inviteErrorMessage = nil

        Task {
            let input = InviteCreateInput(
                kind: .agent,
                displayName: actor.displayName,
                agentKind: actor.agentKind ?? "daemon",
                targetActorID: actor.actorId
            )
            let invite = await store.createInvite(input)
            await MainActor.run {
                isCreatingInvite = false
                if let invite {
                    createdInvite = invite
                    showInviteSheet = true
                } else {
                    inviteErrorMessage = store.errorMessage ?? "Failed to create invite."
                }
            }
        }
    }

    private func addWorkspace() {
        let path = newWorkspacePath.trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty else { return }

        guard !daemonDeviceID.isEmpty else {
            workspaceErrorMessage = "Missing daemon device ID."
            return
        }
        guard mqtt.connectionState == .connected else {
            workspaceErrorMessage = "MQTT is not connected."
            return
        }

        isAddingWorkspace = true
        workspaceErrorMessage = nil

        Task {
            var envelope = Amux_DeviceCommandEnvelope()
            envelope.deviceID = daemonDeviceID
            envelope.peerID = peerID
            envelope.commandID = UUID().uuidString
            envelope.timestamp = Int64(Date().timeIntervalSince1970)

            var add = Amux_AddWorkspace()
            add.path = path

            var cmd = Amux_DeviceCollabCommand()
            cmd.command = .addWorkspace(add)
            envelope.command = cmd

            do {
                let data = try ProtoMQTTCoder.encode(envelope)
                try await mqtt.publish(topic: MQTTTopics.deviceCollab(teamID: actor.teamId, deviceID: daemonDeviceID), payload: data)
            } catch {
                await MainActor.run {
                    isAddingWorkspace = false
                    workspaceErrorMessage = "Failed to send: \(error.localizedDescription)"
                }
                return
            }

            let stream = mqtt.messages()
            let collabTopic = MQTTTopics.deviceCollab(teamID: actor.teamId, deviceID: daemonDeviceID)
            let deadline = Date().addingTimeInterval(10)
            for await msg in stream {
                if Date() > deadline { break }
                if msg.topic == collabTopic,
                   let dce = try? ProtoMQTTCoder.decode(Amux_DeviceCollabEvent.self, from: msg.payload),
                   case .workspaceResult(let result) = dce.event,
                   result.commandID == envelope.commandID {
                    await MainActor.run {
                        isAddingWorkspace = false
                        if result.success {
                            newWorkspacePath = ""
                            workspaceErrorMessage = nil
                            let workspaceStore = self.workspaceStore
                            Task {
                                await workspaceStore?.reload(agentID: actor.actorId)
                            }
                        } else {
                            workspaceErrorMessage = result.error
                        }
                    }
                    return
                }
            }

            await MainActor.run {
                isAddingWorkspace = false
                workspaceErrorMessage = "Timed out waiting for workspace response on \(collabTopic)"
            }
        }
    }

    private func grantAuthorizedMembers(_ members: [CachedActor]) {
        guard !members.isEmpty, let authorizedHumansStore else { return }
        isGrantingAuthorizedMembers = true
        Task {
            var firstFailure: String?
            for member in members {
                let ok = await authorizedHumansStore.grant(memberID: member.actorId)
                if !ok, firstFailure == nil {
                    firstFailure = authorizedHumansStore.errorMessage ?? "Failed to authorize member."
                }
            }

            await MainActor.run {
                isGrantingAuthorizedMembers = false
                if let firstFailure {
                    authorizedHumansStore.errorMessage = firstFailure
                }
            }
        }
    }
}

private struct InviteShareSheet: View {
    @Environment(\.dismiss) private var dismiss
    let invite: InviteCreated

    var body: some View {
        NavigationStack {
            Form {
                Section("Share invite") {
                    Text(invite.deeplink)
                        .font(.footnote)
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                    ShareLink(item: invite.deeplink) {
                        Label("Share link", systemImage: "square.and.arrow.up")
                    }
                    Button {
                        UIPasteboard.general.string = invite.deeplink
                    } label: {
                        Label("Copy link", systemImage: "doc.on.doc")
                    }
                    LabeledContent(
                        "Expires",
                        value: invite.expiresAt.formatted(date: .abbreviated, time: .shortened)
                    )
                    .font(.caption)
                }
            }
            .navigationTitle("Agent Invite")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

private struct AuthorizedHumanRow: View {
    let human: AgentAuthorizedHuman
    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(human.isOnline ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(human.displayName).font(.body)
                Text(human.permissionLevel.capitalized)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(human.isOnline ? "Online" : "Offline")
                .font(.caption)
                .foregroundStyle(human.isOnline ? .green : .secondary)
        }
    }
}

private struct AuthorizedMemberPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let candidates: [CachedActor]
    let onConfirm: ([CachedActor]) -> Void

    @State private var selectedIDs: Set<String> = []
    @State private var searchText = ""

    private var filteredCandidates: [CachedActor] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return candidates }
        let normalized = query.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        return candidates.filter { candidate in
            [candidate.displayName, candidate.roleLabel, candidate.actorId]
                .joined(separator: " ")
                .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
                .contains(normalized)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if filteredCandidates.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                } else {
                    ForEach(filteredCandidates, id: \.actorId) { member in
                        Button {
                            if selectedIDs.contains(member.actorId) {
                                selectedIDs.remove(member.actorId)
                            } else {
                                selectedIDs.insert(member.actorId)
                            }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: selectedIDs.contains(member.actorId) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selectedIDs.contains(member.actorId) ? Color.accentColor : .secondary)
                                    .font(.title3)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(member.displayName).font(.body)
                                    Text(member.roleLabel).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Search members")
            .navigationTitle("Add Members")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Add") {
                        onConfirm(candidates.filter { selectedIDs.contains($0.actorId) })
                        dismiss()
                    }
                    .disabled(selectedIDs.isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

#else
struct MemberListContent: View {
    init(store: ActorStore, pairing: PairingManager, mqtt: MQTTService, sessionViewModel: SessionListViewModel) {}
    var body: some View { ContentUnavailableView("Actors", systemImage: "person.2") }
}
#endif
