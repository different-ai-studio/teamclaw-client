import SwiftUI
import SwiftData
import UIKit
import AMUXCore
import os

private let newSessionLogger = Logger(subsystem: "com.amux.app", category: "NewSession")

// MARK: - NewSessionSheet

public struct NewSessionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let mqtt: MQTTService
    let deviceId: String
    let peerId: String
    let teamclawService: TeamclawService?
    let teamID: String
    let currentActorID: String?
    let isAgentAvailable: Bool
    let connectedAgentsStore: ConnectedAgentsStore?

    let viewModel: SessionListViewModel
    let preselectedTaskId: String?
    let preselectedCollaborators: [CachedActor]
    @State private var selectedWorkspaceId: String?
    @State private var selectedAgentType: Amux_AgentType = .claudeCode
    @State private var workspaceStore: WorkspaceStore?

    @State private var collaborators: [CachedActor] = []
    @State private var primaryAgentID: String?
    @State private var selectedTaskId: String?
    @State private var messageText: String = ""
    @State private var showMemberPicker = false
    @State private var primaryAgentCandidates: [CachedActor] = []
    @State private var isSending = false
    @State private var errorMessage: String?
    @State private var debugStatusMessage: String?
    @State private var debugTransportMessage: String?
    @FocusState private var isInputFocused: Bool

    @Query(filter: #Predicate<SessionTask> { !$0.archived },
           sort: \SessionTask.createdAt, order: .reverse)
    private var tasks: [SessionTask]

    private var workspaces: [WorkspaceRecord] { workspaceStore?.workspaces ?? [] }
    private var selectedWorkspaceRecord: WorkspaceRecord? {
        guard shouldShowWorkspaceRow,
              let selectedWorkspaceId else { return nil }
        return workspaces.first(where: { $0.id == selectedWorkspaceId })
    }
    private var availableTasks: [SessionTask] {
        guard let selectedWorkspaceId, !selectedWorkspaceId.isEmpty else { return tasks }
        let scopedTasks = tasks.filter { $0.workspaceId == selectedWorkspaceId }
        return scopedTasks.isEmpty ? tasks : scopedTasks
    }
    private var shouldShowWorkspaceRow: Bool { primaryAgentID != nil }
    private var requesterDeviceID: String {
        UIDevice.current.identifierForVendor?.uuidString ?? "ios-\(peerId)"
    }

    /// Set by parent — called with agentId when session is created
    var onSessionCreated: ((String) -> Void)?

    public init(mqtt: MQTTService, deviceId: String, peerId: String, teamclawService: TeamclawService? = nil,
                teamID: String = "", currentActorID: String? = nil, isAgentAvailable: Bool = true,
                connectedAgentsStore: ConnectedAgentsStore? = nil,
                viewModel: SessionListViewModel,
                preselectedTaskId: String? = nil,
                preselectedCollaborators: [CachedActor] = [],
                onSessionCreated: ((String) -> Void)? = nil) {
        self.mqtt = mqtt
        self.deviceId = deviceId
        self.peerId = peerId
        self.teamclawService = teamclawService
        self.teamID = teamID
        self.currentActorID = currentActorID
        self.isAgentAvailable = isAgentAvailable
        self.connectedAgentsStore = connectedAgentsStore
        self.viewModel = viewModel
        self.preselectedTaskId = preselectedTaskId
        self.preselectedCollaborators = preselectedCollaborators
        self.onSessionCreated = onSessionCreated
    }

    private var canSend: Bool {
        (!shouldShowWorkspaceRow || selectedWorkspaceId != nil) &&
        !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var body: some View {
        NavigationStack {
            ZStack {
                VStack(spacing: 0) {
                    collaboratorsRow
                    Divider()
                    workspaceAndTypeRow
                    Divider()
                    taskRow
                    Divider()
                    Spacer()
                    if let errorMessage {
                        Text(errorMessage)
                            .font(.subheadline)
                            .foregroundStyle(.red)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 8)
                    }
#if DEBUG
                    if let debugStatusMessage, !debugStatusMessage.isEmpty {
                        Text(debugStatusMessage)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 8)
                            .lineLimit(2)
                            .accessibilityIdentifier("newSession.debugStatus")
                    }
                    if let debugTransportMessage, !debugTransportMessage.isEmpty {
                        Text(debugTransportMessage)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 8)
                            .accessibilityIdentifier("newSession.debugTransport")
                    }
#endif
                    inputBar
                }
                if isSending {
                    Color.black.opacity(0.15).ignoresSafeArea()
                    ProgressView("Starting session…")
                        .padding(24)
                        .liquidGlass(in: RoundedRectangle(cornerRadius: 12), interactive: false)
                }
            }
            .allowsHitTesting(!isSending)
            .navigationTitle("New Session")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .sheet(isPresented: $showMemberPicker) {
            MemberListView(
                selected: Set(collaborators.map(\.actorId)),
                accessibleAgentIDs: Set(connectedAgentsStore?.agents.map(\.id) ?? []),
                currentPrimaryAgentID: primaryAgentID,
                excludeActorID: currentActorID
            ) { selected in
                collaborators = selected
                let agents = selected.filter { $0.isAgent }
                // Primary agent needed when no session exists yet OR the
                // current primary is no longer in the selection. Show the
                // confirmation sheet when we have candidates to pick from.
                let needsPrimary = primaryAgentID == nil
                    || !agents.contains(where: { $0.actorId == primaryAgentID })
                if needsPrimary {
                    if agents.count == 1 {
                        primaryAgentID = agents[0].actorId
                    } else if agents.count > 1 {
                        primaryAgentCandidates = agents
                    } else {
                        primaryAgentID = nil
                    }
                }
            }
            // Refresh the connected-agents set each time the picker opens so
            // agents that came online since the last fetch aren't filtered out.
            // @Observable on ConnectedAgentsStore propagates the reload into
            // accessibleAgentIDs without an explicit re-bind.
            .task { await connectedAgentsStore?.reload() }
        }
        .sheet(isPresented: Binding(
            get: { !primaryAgentCandidates.isEmpty },
            set: { if !$0 { primaryAgentCandidates = [] } }
        )) {
            PrimaryAgentSheet(candidates: primaryAgentCandidates) { id in
                primaryAgentID = id
                primaryAgentCandidates = []
            }
        }
        .onAppear {
            isInputFocused = true
            if selectedTaskId == nil, let preselectedTaskId {
                selectedTaskId = preselectedTaskId
                if shouldShowWorkspaceRow,
                   let task = tasks.first(where: { $0.taskId == preselectedTaskId }),
                   !task.workspaceId.isEmpty {
                    selectedWorkspaceId = task.workspaceId
                }
            }
            if collaborators.isEmpty, !preselectedCollaborators.isEmpty {
                collaborators = preselectedCollaborators
            }
        }
        .onChange(of: selectedTaskId) { _, newTaskId in
            guard let newTaskId,
                  shouldShowWorkspaceRow,
                  let task = tasks.first(where: { $0.taskId == newTaskId }),
                  !task.workspaceId.isEmpty else {
                return
            }
            selectedWorkspaceId = task.workspaceId
        }
        .onChange(of: selectedWorkspaceId) { _, newWorkspaceId in
            guard let selectedTaskId,
                  let task = tasks.first(where: { $0.taskId == selectedTaskId }) else {
                return
            }
            guard let newWorkspaceId, !newWorkspaceId.isEmpty else { return }
            if !task.workspaceId.isEmpty && task.workspaceId != newWorkspaceId {
                self.selectedTaskId = nil
            }
        }
        .task {
            guard workspaceStore == nil, !teamID.isEmpty else { return }
            if let repository = try? SupabaseWorkspaceRepository() {
                workspaceStore = WorkspaceStore(teamID: teamID, repository: repository)
                await reloadWorkspacesForPrimaryAgent()
            }
        }
        .onChange(of: primaryAgentID) { _, _ in
            Task { await reloadWorkspacesForPrimaryAgent() }
        }
    }

    // MARK: - Workspace & Agent Type row

    private var workspaceAndTypeRow: some View {
        VStack(spacing: 0) {
            if shouldShowWorkspaceRow {
                HStack {
                    Text("Workspace")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Menu {
                        if workspaces.isEmpty {
                            Text("No workspaces available")
                        } else {
                            ForEach(workspaces) { ws in
                                Button {
                                    selectedWorkspaceId = ws.id
                                } label: {
                                    Label(ws.displayName, systemImage: selectedWorkspaceId == ws.id ? "checkmark" : "folder")
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(selectedWorkspaceName)
                                .font(.body)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption)
                        }
                        .foregroundStyle(selectedWorkspaceId == nil ? .secondary : .primary)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }

            if isAgentAvailable && shouldShowWorkspaceRow {
                Divider()
                HStack {
                    Text("Agent")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Picker("Agent", selection: $selectedAgentType) {
                        Text("Claude").tag(Amux_AgentType.claudeCode)
                        Text("OpenCode").tag(Amux_AgentType.opencode)
                        Text("Codex").tag(Amux_AgentType.codex)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 240)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
    }

    private var selectedWorkspaceName: String {
        if let id = selectedWorkspaceId,
           let ws = workspaces.first(where: { $0.id == id }) {
            return ws.displayName
        }
        return "Select\u{2026}"
    }

    @MainActor
    private func reloadWorkspacesForPrimaryAgent() async {
        guard let workspaceStore else { return }
        await workspaceStore.reload(agentID: primaryAgentID)

        if !shouldShowWorkspaceRow {
            selectedWorkspaceId = nil
            return
        }

        if let selectedWorkspaceId,
           workspaces.contains(where: { $0.id == selectedWorkspaceId }) {
            return
        }

        selectedWorkspaceId = workspaces.count == 1 ? workspaces.first?.id : nil
    }

    // MARK: - Collaborators row

    private var collaboratorsRow: some View {
        HStack(alignment: .center, spacing: 8) {
            Text("Collaborators")
                .foregroundStyle(.secondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    if collaborators.isEmpty {
                        Text("Just you")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(collaborators, id: \.actorId) { member in
                            CollaboratorChip(name: member.displayName) {
                                removeCollaborator(member)
                            }
                        }
                    }
                }
                .padding(.vertical, 1)
            }

            Spacer(minLength: 0)

            Button {
                showMemberPicker = true
                isInputFocused = false
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.title3)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    // MARK: - Task row

    private var taskRow: some View {
        HStack(alignment: .center, spacing: 8) {
            Text("Task")
                .foregroundStyle(.secondary)
            Spacer()
            Menu {
                Button {
                    selectedTaskId = nil
                } label: {
                    Label("None", systemImage: selectedTaskId == nil ? "checkmark" : "circle")
                }
                if !availableTasks.isEmpty {
                    Divider()
                    ForEach(availableTasks, id: \.taskId) { item in
                        Button {
                            selectedTaskId = item.taskId
                        } label: {
                            Label(item.displayTitle,
                                  systemImage: selectedTaskId == item.taskId ? "checkmark" : "circle")
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(selectedTaskLabel)
                        .font(.body)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption)
                }
                .foregroundStyle(selectedTaskId == nil ? .secondary : .primary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var selectedTaskLabel: String {
        if let id = selectedTaskId,
           let item = tasks.first(where: { $0.taskId == id }) {
            return item.displayTitle
        }
        if let selectedWorkspaceId,
           tasks.contains(where: { $0.workspaceId == selectedWorkspaceId }) {
            return "Select…"
        }
        return "None"
    }

    // MARK: - Input bar

    private var inputBar: some View {
        LiquidGlassContainer(spacing: 8) {
            HStack(alignment: .bottom, spacing: 8) {
                HStack(alignment: .bottom, spacing: 4) {
                    TextField("Message", text: $messageText, axis: .vertical)
                        .font(.body)
                        .lineLimit(1...5)
                        .focused($isInputFocused)
                        .accessibilityIdentifier("newSession.messageField")
                        .padding(.leading, 14)
                        .padding(.trailing, 4)
                        .padding(.vertical, 10)

                    Button(action: sendAndCreate) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(canSend ? .blue : .gray.opacity(0.4))
                    }
                    .accessibilityIdentifier("newSession.sendButton")
                    .buttonStyle(.plain)
                    .disabled(!canSend)
                    .padding(.trailing, 6)
                    .padding(.bottom, 6)
                }
                .liquidGlass(in: RoundedRectangle(cornerRadius: 20))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .padding(.bottom, 4)
    }

    // MARK: - Helpers

    /// Builds the text that will be sent as the session's first user message.
    /// If a task is selected, its title/description prefaces the user's prompt
    /// so the agent has that context upfront.
    private func firstMessageText(userText: String) -> String {
        guard let id = selectedTaskId,
              let item = tasks.first(where: { $0.taskId == id }) else {
            return userText
        }
        let description = item.taskDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = item.displayTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let taskBlock: String
        if !description.isEmpty && !title.isEmpty && description != title {
            taskBlock = "Task: \(title)\n\n\(description)"
        } else if !description.isEmpty {
            taskBlock = "Task: \(description)"
        } else if !title.isEmpty {
            taskBlock = "Task: \(title)"
        } else {
            return userText
        }
        return "\(taskBlock)\n\n\(userText)"
    }

    /// Removes a collaborator chip. If the removed actor was the primary
    /// agent, the primary is cleared and — as long as there are other agents
    /// still in the collaborator list — the primary-agent picker is shown so
    /// the user can pick a replacement.
    private func removeCollaborator(_ member: CachedActor) {
        collaborators.removeAll { $0.actorId == member.actorId }
        guard primaryAgentID == member.actorId else { return }
        primaryAgentID = nil
        let remainingAgents = collaborators.filter { $0.isAgent }
        if remainingAgents.count == 1 {
            primaryAgentID = remainingAgents[0].actorId
        } else if remainingAgents.count > 1 {
            primaryAgentCandidates = remainingAgents
        }
    }

    private func sendAndCreate() {
        let userText = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !userText.isEmpty else { return }

        // When a task is picked, prepend its context so the session's first
        // user message carries the task description + the typed prompt.
        let text = firstMessageText(userText: userText)

        isInputFocused = false
        errorMessage = nil
        debugStatusMessage = nil

        if !isAgentAvailable {
            createLocalSession(text: text, title: userText)
            return
        }

        // Shared-session path also handles the case where a task was picked but no
        // collaborators were added — ACP startAgent has no taskId field,
        // so task linking must flow through CreateSessionRequest.
        if !collaborators.isEmpty || selectedTaskId != nil {
            createSharedSession(text: text, title: userText)
            return
        }

        isSending = true

        let titleSeed = String(userText.prefix(50)).trimmingCharacters(in: .whitespacesAndNewlines)

        Task {
            guard let teamclawService else {
                await MainActor.run {
                    isSending = false
                    errorMessage = "TeamclawService unavailable."
                }
                return
            }

            let routeDevice = effectiveDeviceID
            guard !routeDevice.isEmpty, routeDevice != requesterDeviceID else {
                await MainActor.run {
                    isSending = false
                    errorMessage = "Daemon device ID is not configured."
                }
                return
            }

            await MainActor.run {
                debugStatusMessage = "starting runtime…"
                debugTransportMessage = "team=\(effectiveTeamID) route=\(routeDevice) reply=\(requesterDeviceID) (RPC)"
            }

            let outcome = await teamclawService.runtimeStartRpc(
                agentType: selectedAgentType,
                workspaceId: selectedWorkspaceRecord?.id ?? "",
                worktree: selectedWorkspaceRecord?.path ?? "",
                sessionId: "",
                initialPrompt: text
            )

            await MainActor.run {
                isSending = false
                switch outcome {
                case .accepted(let runtimeID, _):
                    persistPlaceholderAgent(
                        agentID: runtimeID,
                        title: titleSeed,
                        prompt: text
                    )
                    newSessionLogger.info(
                        "new-session accepted runtimeID=\(runtimeID, privacy: .public) (lifecycle on runtime/state)"
                    )
                    onSessionCreated?(runtimeID)
                    dismiss()
                case .rejected(let reason):
                    errorMessage = reason.isEmpty ? "Agent failed to start. Check daemon logs." : reason
                }
            }
        }
    }

    /// Routing team_id for teamclaw RPCs. Real Supabase team UUID when
    /// available; falls back to the legacy hardcoded bucket otherwise.
    private var effectiveTeamID: String {
        teamID.isEmpty ? "teamclaw" : teamID
    }

    /// Daemon device UUID to publish MQTT commands at. Picks the primary
    /// agent's registered `agents.device_id` when set (populated by the
    /// daemon on start), otherwise falls back to the user-typed value in
    /// Settings for older daemons.
    private var effectiveDeviceID: String {
        if let primary = primaryAgentID,
           let agent = connectedAgentsStore?.agents.first(where: { $0.id == primary }),
           let id = agent.deviceID, !id.isEmpty {
            return id
        }

        let configuredDeviceID = deviceId.trimmingCharacters(in: .whitespacesAndNewlines)
        if !configuredDeviceID.isEmpty, configuredDeviceID != requesterDeviceID {
            return configuredDeviceID
        }

        let inferredDeviceIDs = connectedAgentsStore?.agents.sorted(by: { lhs, rhs in
            if lhs.isOnline != rhs.isOnline {
                return lhs.isOnline && !rhs.isOnline
            }
            return (lhs.lastActiveAt ?? .distantPast) > (rhs.lastActiveAt ?? .distantPast)
        }).compactMap(\.deviceID)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        if let inferredDeviceID = inferredDeviceIDs?
            .first(where: { !$0.isEmpty && $0 != requesterDeviceID }) {
            return inferredDeviceID
        }

        return configuredDeviceID
    }

    private func createSharedSession(text: String, title: String) {
        guard let currentActorID else {
            errorMessage = "Current actor is not ready yet."
            return
        }

        isSending = true

        let sessionID = UUID().uuidString.lowercased()
        let trimmedTitle = String(title.prefix(50)).trimmingCharacters(in: .whitespacesAndNewlines)
        let createdAt = Date()
        let participantActors = sessionParticipants(currentActorID: currentActorID)
        let participantInfos = sessionInfoParticipants(
            currentActorID: currentActorID,
            createdAt: createdAt,
            participants: participantActors
        )
        let info = makeSessionInfo(
            sessionID: sessionID,
            title: trimmedTitle,
            summary: text,
            createdAt: createdAt,
            currentActorID: currentActorID,
            participants: participantInfos
        )

        Task {
            do {
                let repository = try SupabaseSessionRepository()
                try await repository.createSession(
                    SessionCreateInput(
                        id: sessionID,
                        teamID: effectiveTeamID,
                        taskID: selectedTaskId,
                        createdByActorID: currentActorID,
                        primaryAgentID: primaryAgentID,
                        title: trimmedTitle,
                        summary: text,
                        participants: participantActors.map { SessionParticipantInput(actorID: $0.actorId) }
                    )
                )

                teamclawService?.subscribeToSession(sessionID)
                await MainActor.run {
                    let session = persistSession(info)
                    session.primaryAgentId = primaryAgentID
                    try? modelContext.save()
                    viewModel.reloadSessions(modelContext: modelContext)
                }

                if let primaryAgentID, !primaryAgentID.isEmpty {
                    _ = try await startAgentAndWaitForState(
                        initialPrompt: text,
                        sessionID: sessionID
                    )
                }
                teamclawService?.sendMessage(sessionId: sessionID, content: text)

                await MainActor.run {
                    isSending = false
                    newSessionLogger.info(
                        "shared-session success destination=collab:\(sessionID, privacy: .public)"
                    )
                    onSessionCreated?("collab:\(sessionID)")
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    isSending = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func createLocalSession(text: String, title: String) {
        guard let currentActorID else {
            errorMessage = "Current actor is not ready yet."
            return
        }

        let createdAt = Date()
        let sessionID = UUID().uuidString
        let session = Session(
            sessionId: sessionID,
            mode: "collab",
            teamId: teamID,
            title: String(title.prefix(50)).trimmingCharacters(in: .whitespacesAndNewlines),
            createdBy: currentActorID,
            createdAt: createdAt,
            summary: text,
            participantCount: max(collaborators.count + 1, 1),
            lastMessagePreview: text,
            lastMessageAt: createdAt,
            taskId: selectedTaskId ?? ""
        )

        let message = SessionMessage(
            messageId: UUID().uuidString,
            sessionId: sessionID,
            senderActorId: currentActorID,
            kind: "text",
            content: text,
            createdAt: createdAt
        )

        modelContext.insert(session)
        modelContext.insert(message)
        try? modelContext.save()
        viewModel.reloadSessions(modelContext: modelContext)
        onSessionCreated?("collab:\(sessionID)")
        dismiss()
    }

    private func persistSession(_ info: Teamclaw_SessionInfo) -> Session {
        let sessionID = info.sessionID
        let fetch = FetchDescriptor<Session>(
            predicate: #Predicate { $0.sessionId == sessionID }
        )

        let session = (try? modelContext.fetch(fetch))?.first ?? {
            let newSession = Session(
                sessionId: info.sessionID,
                mode: "collab",
                teamId: info.teamID,
                title: info.title,
                createdBy: info.createdBy,
                createdAt: Date(timeIntervalSince1970: TimeInterval(info.createdAt)),
                summary: info.summary,
                participantCount: info.participants.count,
                lastMessagePreview: info.lastMessagePreview,
                lastMessageAt: info.lastMessageAt > 0
                    ? Date(timeIntervalSince1970: TimeInterval(info.lastMessageAt))
                    : nil,
                taskId: info.taskID
            )
            modelContext.insert(newSession)
            return newSession
        }()

        session.mode = "collab"
        session.teamId = info.teamID
        session.title = info.title
        session.createdBy = info.createdBy
        session.createdAt = Date(timeIntervalSince1970: TimeInterval(info.createdAt))
        session.summary = info.summary
        session.participantCount = info.participants.count
        session.lastMessagePreview = info.lastMessagePreview
        session.lastMessageAt = info.lastMessageAt > 0
            ? Date(timeIntervalSince1970: TimeInterval(info.lastMessageAt))
            : nil
        session.taskId = info.taskID
        session.primaryAgentId = info.primaryAgentID.isEmpty ? nil : info.primaryAgentID
        try? modelContext.save()
        return session
    }

    @MainActor
    private func persistPlaceholderAgent(agentID: String, title: String, prompt: String) {
        guard !agentID.isEmpty else { return }

        let fetch = FetchDescriptor<Runtime>(
            predicate: #Predicate { $0.runtimeId == agentID }
        )

        let runtime = (try? modelContext.fetch(fetch))?.first ?? {
            let created = Runtime(
                runtimeId: agentID,
                agentType: Int(selectedAgentType.rawValue),
                status: 1,
                startedAt: .now,
                currentPrompt: prompt,
                workspaceId: selectedWorkspaceRecord?.id ?? ""
            )
            modelContext.insert(created)
            return created
        }()

        runtime.agentType = Int(selectedAgentType.rawValue)
        runtime.status = 1
        runtime.currentPrompt = prompt
        if let workspaceId = selectedWorkspaceRecord?.id, !workspaceId.isEmpty {
            runtime.workspaceId = workspaceId
        }
        runtime.sessionTitle = title
        runtime.lastEventTime = .now
        try? modelContext.save()

        viewModel.runtimes = (try? modelContext.fetch(
            FetchDescriptor<Runtime>(sortBy: [SortDescriptor(\.lastEventTime, order: .reverse)])
        )) ?? []
    }

    private func waitForSessionInfoResponse(
        requestId: String,
        timeout: TimeInterval,
        stream: AsyncStream<MQTTIncoming>
    ) async throws -> Teamclaw_SessionInfo? {
        let deadline = Date().addingTimeInterval(timeout)
        for await msg in stream {
            if Date() > deadline { return nil }
            guard msg.topic.contains("/rpc/"),
                  msg.topic.hasSuffix("/res"),
                  let response = try? Teamclaw_RpcResponse(serializedBytes: msg.payload),
                  response.requestID == requestId else {
                continue
            }

            if !response.error.isEmpty {
                throw SessionCreationError.rpc(response.error)
            }
            guard response.success, case .sessionInfo(let info) = response.result else {
                throw SessionCreationError.rpc("Session creation returned no session info")
            }
            return info
        }
        return nil
    }

    private func startAgentAndWaitForState(initialPrompt: String, sessionID: String) async throws -> String {
        guard let teamclawService else {
            throw SessionCreationError.rpc("TeamclawService unavailable.")
        }

        let routeDevice = effectiveDeviceID
        guard !routeDevice.isEmpty, routeDevice != requesterDeviceID else {
            throw SessionCreationError.rpc("Daemon device ID is not configured.")
        }

        await MainActor.run {
            debugStatusMessage = "starting runtime for session \(sessionID)…"
            debugTransportMessage = "team=\(effectiveTeamID) route=\(routeDevice) reply=\(requesterDeviceID) (RPC)"
        }

        let outcome = await teamclawService.runtimeStartRpc(
            agentType: selectedAgentType,
            workspaceId: selectedWorkspaceRecord?.id ?? "",
            worktree: selectedWorkspaceRecord?.path ?? "",
            sessionId: sessionID,
            initialPrompt: initialPrompt
        )

        switch outcome {
        case .accepted(let runtimeID, _):
            return runtimeID
        case .rejected(let reason):
            throw SessionCreationError.rpc(reason.isEmpty ? "Agent failed to start. Check daemon logs." : reason)
        }
    }

    private enum SessionCreationError: LocalizedError {
        case rpc(String)

        var errorDescription: String? {
            switch self {
            case .rpc(let message):
                return message
            }
        }
    }

    private func sessionParticipants(currentActorID: String) -> [CachedActor] {
        var deduped: [String: CachedActor] = collaborators.reduce(into: [:]) { partialResult, actor in
            partialResult[actor.actorId] = actor
        }

        if deduped[currentActorID] == nil {
            deduped[currentActorID] = CachedActor(
                actorId: currentActorID,
                teamId: teamID,
                actorType: "member",
                displayName: teamclawService?.localDisplayName.isEmpty == false ? teamclawService?.localDisplayName ?? currentActorID : currentActorID,
                teamRole: "member"
            )
        }

        if let primaryAgentID,
           deduped[primaryAgentID] == nil,
           let primaryAgent = collaborators.first(where: { $0.actorId == primaryAgentID }) {
            deduped[primaryAgentID] = primaryAgent
        }

        return Array(deduped.values)
    }

    private func sessionInfoParticipants(
        currentActorID: String,
        createdAt: Date,
        participants: [CachedActor]
    ) -> [Teamclaw_Participant] {
        participants.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
            .map { actor in
                var participant = Teamclaw_Participant()
                participant.actorID = actor.actorId
                participant.actorType = actor.isAgent ? .personalAgent : .human
                participant.displayName = actor.actorId == currentActorID && !(teamclawService?.localDisplayName ?? "").isEmpty
                    ? teamclawService?.localDisplayName ?? actor.displayName
                    : actor.displayName
                participant.joinedAt = Int64(createdAt.timeIntervalSince1970)
                return participant
            }
    }

    private func makeSessionInfo(
        sessionID: String,
        title: String,
        summary: String,
        createdAt: Date,
        currentActorID: String,
        participants: [Teamclaw_Participant]
    ) -> Teamclaw_SessionInfo {
        var info = Teamclaw_SessionInfo()
        info.sessionID = sessionID
        info.sessionType = .collab
        info.teamID = effectiveTeamID
        info.title = title
        info.createdBy = currentActorID
        info.createdAt = Int64(createdAt.timeIntervalSince1970)
        info.participants = participants
        info.summary = summary
        info.primaryAgentID = primaryAgentID ?? ""
        info.taskID = selectedTaskId ?? ""
        return info
    }
}

// MARK: - CollaboratorChip

private struct CollaboratorChip: View {
    let name: String
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(name)
                .font(.subheadline)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.semibold))
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .padding(.vertical, 5)
        .foregroundStyle(.primary)
        .liquidGlass(in: Capsule(), interactive: false)
    }
}
