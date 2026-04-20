import SwiftUI
import SwiftData
import AMUXCore

// MARK: - NewSessionSheet

public struct NewSessionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let mqtt: MQTTService
    let deviceId: String
    let peerId: String
    let teamclawService: TeamclawService?

    let viewModel: SessionListViewModel
    let preselectedTaskId: String?
    let preselectedCollaborators: [Member]
    @State private var selectedWorkspaceId: String?
    @State private var selectedAgentType: Amux_AgentType = .claudeCode

    @State private var collaborators: [Member] = []
    @State private var selectedTaskId: String?
    @State private var messageText: String = ""
    @State private var showMemberPicker = false
    @State private var isSending = false
    @State private var errorMessage: String?
    @FocusState private var isInputFocused: Bool

    @Query(filter: #Predicate<SessionTask> { !$0.archived },
           sort: \SessionTask.createdAt, order: .reverse)
    private var tasks: [SessionTask]

    private var workspaces: [Workspace] { viewModel.workspaces }

    /// Set by parent — called with agentId when session is created
    var onSessionCreated: ((String) -> Void)?

    public init(mqtt: MQTTService, deviceId: String, peerId: String, teamclawService: TeamclawService? = nil, viewModel: SessionListViewModel,
                preselectedTaskId: String? = nil,
                preselectedCollaborators: [Member] = [],
                onSessionCreated: ((String) -> Void)? = nil) {
        self.mqtt = mqtt
        self.deviceId = deviceId
        self.peerId = peerId
        self.teamclawService = teamclawService
        self.viewModel = viewModel
        self.preselectedTaskId = preselectedTaskId
        self.preselectedCollaborators = preselectedCollaborators
        self.onSessionCreated = onSessionCreated
    }

    private var canSend: Bool {
        selectedWorkspaceId != nil &&
        !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var body: some View {
        NavigationStack {
            ZStack {
                VStack(spacing: 0) {
                    workspaceAndTypeRow
                    Divider()
                    collaboratorsRow
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
            MemberListView(mqtt: mqtt, deviceId: deviceId, peerId: peerId,
                           selected: Set(collaborators.map(\.memberId))) { selected in
                collaborators = selected
            }
        }
        .onAppear {
            isInputFocused = true
            if workspaces.count == 1 {
                selectedWorkspaceId = workspaces.first?.workspaceId
            }
            if selectedTaskId == nil, let preselectedTaskId {
                selectedTaskId = preselectedTaskId
                if let task = tasks.first(where: { $0.taskId == preselectedTaskId }),
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
                  let task = tasks.first(where: { $0.taskId == newTaskId }),
                  !task.workspaceId.isEmpty else {
                return
            }
            selectedWorkspaceId = task.workspaceId
        }
    }

    // MARK: - Workspace & Agent Type row

    private var workspaceAndTypeRow: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Workspace")
                    .foregroundStyle(.secondary)
                Spacer()
                Menu {
                    ForEach(workspaces, id: \.workspaceId) { ws in
                        Button {
                            selectedWorkspaceId = ws.workspaceId
                        } label: {
                            Label(ws.displayName, systemImage: selectedWorkspaceId == ws.workspaceId ? "checkmark" : "folder")
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

    private var selectedWorkspaceName: String {
        if let id = selectedWorkspaceId,
           let ws = workspaces.first(where: { $0.workspaceId == id }) {
            return ws.displayName
        }
        return "Select\u{2026}"
    }

    // MARK: - Collaborators row

    private var collaboratorsRow: some View {
        HStack(alignment: .center, spacing: 8) {
            Text("Collaborators")
                .foregroundStyle(.secondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(collaborators, id: \.memberId) { member in
                        CollaboratorChip(name: member.displayName) {
                            collaborators.removeAll { $0.memberId == member.memberId }
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
                if !tasks.isEmpty {
                    Divider()
                    ForEach(tasks, id: \.taskId) { item in
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
        return "None"
    }

    // MARK: - Input bar

    private var inputBar: some View {
        LiquidGlassContainer(spacing: 8) {
            HStack(alignment: .bottom, spacing: 8) {
                Button {} label: {
                    Image(systemName: "plus")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(.primary)
                        .frame(width: 40, height: 40)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .liquidGlass(in: Circle())

                HStack(alignment: .bottom, spacing: 4) {
                    TextField("Message", text: $messageText, axis: .vertical)
                        .font(.body)
                        .lineLimit(1...5)
                        .focused($isInputFocused)
                        .padding(.leading, 14)
                        .padding(.trailing, 4)
                        .padding(.vertical, 10)

                    Button(action: sendAndCreate) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(canSend ? .blue : .gray.opacity(0.4))
                    }
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

    private func sendAndCreate() {
        let userText = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !userText.isEmpty else { return }

        // When a task is picked, prepend its context so the session's first
        // user message carries the task description + the typed prompt.
        let text = firstMessageText(userText: userText)

        isInputFocused = false
        errorMessage = nil

        // Shared-session path also handles the case where a task was picked but no
        // collaborators were added — ACP startAgent has no taskId field,
        // so task linking must flow through CreateSessionRequest.
        if !collaborators.isEmpty || selectedTaskId != nil {
            createSharedSession(text: text, title: userText)
            return
        }

        isSending = true

        Task {
            // Listen for per-agent state publishes instead of the old bulk
            // AgentList — the daemon now fans each session out to its own
            // retained `agent/{id}/state` topic to stay under the broker's
            // 10 KB per-packet cap.
            let stream = mqtt.messages()

            let cmd = makeStartAgentCommand(initialPrompt: text)

            do {
                let data = try ProtoMQTTCoder.encode(cmd)
                try await mqtt.publish(topic: "amux/\(deviceId)/agent/new/commands", payload: data)
            } catch {
                isSending = false
                errorMessage = "Failed to send: \(error.localizedDescription)"
                return
            }

            // Wait up to 15s for the new agent's state publish or a rejection.
            let collabTopic = "amux/\(deviceId)/collab"
            let deadline = Date().addingTimeInterval(15)
            for await msg in stream {
                if Date() > deadline { break }

                // Check for rejection on collab topic
                if msg.topic == collabTopic,
                   let dce = try? ProtoMQTTCoder.decode(Amux_DeviceCollabEvent.self, from: msg.payload),
                   !dce.commandRejected.reason.isEmpty {
                    isSending = false
                    errorMessage = dce.commandRejected.reason
                    return
                }

                // Check for new agent state publish matching our prompt.
                if isAgentStateTopic(msg.topic),
                   !msg.payload.isEmpty,
                   let info = try? ProtoMQTTCoder.decode(Amux_AgentInfo.self, from: msg.payload),
                   info.currentPrompt == text {
                    let agentId = info.agentID
                    isSending = false
                    onSessionCreated?(agentId)
                    dismiss()
                    return
                }
            }

            // Timeout
            isSending = false
            errorMessage = "Session creation timed out. Check daemon logs."
        }
    }

    /// v1: team_id matches daemon.toml config. Must be kept in sync.
    private static let teamId = "teamclaw"

    private func createSharedSession(text: String, title: String) {
        isSending = true

        // Build CreateSessionRequest RPC
        let createReq = teamclawService?.makeCreateSessionRequest(
            teamId: Self.teamId,
            title: String(title.prefix(50)).trimmingCharacters(in: .whitespacesAndNewlines),
            summary: text,
            inviteActorIds: collaborators.map(\.memberId),
            taskId: selectedTaskId ?? ""
        ) ?? {
            var req = Teamclaw_CreateSessionRequest()
            req.sessionType = .collab
            req.teamID = Self.teamId
            req.title = String(title.prefix(50)).trimmingCharacters(in: .whitespacesAndNewlines)
            req.summary = text
            req.inviteActorIds = collaborators.map(\.memberId)
            if let taskId = selectedTaskId, !taskId.isEmpty {
                req.taskID = taskId
            }
            return req
        }()

        var rpcReq = Teamclaw_RpcRequest()
        rpcReq.requestID = String(UUID().uuidString.prefix(8)).lowercased()
        rpcReq.senderDeviceID = deviceId
        rpcReq.method = .createSession(createReq)

        // Send RPC to local amuxd (teamId in topic must match daemon's team_id)
        let requestId = rpcReq.requestID
        let topic = "teamclaw/\(Self.teamId)/rpc/\(deviceId)/\(requestId)/req"
        Task {
            // Subscribe to RPC responses for this device
            let responseTopic = "teamclaw/\(Self.teamId)/rpc/\(deviceId)/+/res"
            try? await mqtt.subscribe(responseTopic)
            // Install the stream before publishing so a fast local host response
            // can't arrive and get dropped before we start iterating.
            let rpcStream = mqtt.messages()

            guard let data = try? rpcReq.serializedData() else {
                isSending = false
                errorMessage = "Failed to encode request"
                return
            }
            do {
                try await mqtt.publish(topic: topic, payload: data, retain: false)
                guard let info = try await waitForSessionInfoResponse(
                    requestId: requestId,
                    timeout: 10,
                    stream: rpcStream
                ) else {
                    isSending = false
                    errorMessage = "Session creation timed out"
                    return
                }

                teamclawService?.subscribeToSession(info.sessionID)
                let session = persistSession(info)

                try await addLocalHumanParticipantIfNeeded(sessionId: info.sessionID, hostDeviceId: info.hostDeviceID)
                let agentId = try await startAgentAndWaitForState(initialPrompt: "")
                try await addAgentParticipant(sessionId: info.sessionID, hostDeviceId: info.hostDeviceID, agentId: agentId)

                session.primaryAgentId = agentId
                let localParticipantCount = (teamclawService?.currentHumanActorId == nil) ? 1 : 2
                session.participantCount = max(session.participantCount, localParticipantCount)
                try? modelContext.save()
                viewModel.reloadSessions(modelContext: modelContext)

                teamclawService?.sendMessage(sessionId: info.sessionID, content: text)

                isSending = false
                onSessionCreated?("collab:\(info.sessionID)")
                dismiss()
            } catch {
                isSending = false
                errorMessage = error.localizedDescription
            }
        }
    }

    private func makeStartAgentCommand(initialPrompt: String) -> Amux_CommandEnvelope {
        var cmd = Amux_CommandEnvelope()
        cmd.agentID = ""
        cmd.deviceID = deviceId
        cmd.peerID = peerId
        cmd.commandID = UUID().uuidString
        cmd.timestamp = Int64(Date().timeIntervalSince1970)

        var start = Amux_AcpStartAgent()
        start.agentType = selectedAgentType
        start.workspaceID = selectedWorkspaceId ?? ""
        start.worktree = ""
        start.initialPrompt = initialPrompt

        var acpCmd = Amux_AcpCommand()
        acpCmd.command = .startAgent(start)
        cmd.acpCommand = acpCmd
        return cmd
    }

    private func isAgentStateTopic(_ topic: String) -> Bool {
        let prefix = "amux/\(deviceId)/agent/"
        return topic.hasPrefix(prefix) && topic.hasSuffix("/state")
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
                hostDeviceId: info.hostDeviceID,
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
        session.hostDeviceId = info.hostDeviceID
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

    private func startAgentAndWaitForState(initialPrompt: String) async throws -> String {
        let knownAgentIds = Set(viewModel.agents.map(\.agentId))
        let stream = mqtt.messages()
        let sentAt = Int64(Date().timeIntervalSince1970)
        let collabTopic = "amux/\(deviceId)/collab"
        let cmd = makeStartAgentCommand(initialPrompt: initialPrompt)

        do {
            let data = try ProtoMQTTCoder.encode(cmd)
            try await mqtt.publish(topic: "amux/\(deviceId)/agent/new/commands", payload: data)
        } catch {
            throw SessionCreationError.rpc("Failed to start agent: \(error.localizedDescription)")
        }

        let deadline = Date().addingTimeInterval(15)
        for await msg in stream {
            if Date() > deadline {
                throw SessionCreationError.rpc("Agent startup timed out. Check daemon logs.")
            }

            if msg.topic == collabTopic,
               let dce = try? ProtoMQTTCoder.decode(Amux_DeviceCollabEvent.self, from: msg.payload),
               !dce.commandRejected.reason.isEmpty {
                throw SessionCreationError.rpc(dce.commandRejected.reason)
            }

            guard isAgentStateTopic(msg.topic),
                  !msg.payload.isEmpty,
                  let info = try? ProtoMQTTCoder.decode(Amux_AgentInfo.self, from: msg.payload) else {
                continue
            }

            if initialPrompt.isEmpty {
                guard !knownAgentIds.contains(info.agentID),
                      info.agentType == selectedAgentType,
                      info.workspaceID == (selectedWorkspaceId ?? ""),
                      info.startedAt >= sentAt else {
                    continue
                }
            } else if info.currentPrompt != initialPrompt {
                continue
            }

            return info.agentID
        }

        throw SessionCreationError.rpc("Agent startup timed out. Check daemon logs.")
    }

    private func addLocalHumanParticipantIfNeeded(sessionId: String, hostDeviceId: String) async throws {
        guard let service = teamclawService,
              let actorId = service.currentHumanActorId else { return }
        let displayName = service.localDisplayName.isEmpty ? actorId : service.localDisplayName
        try await addParticipant(
            sessionId: sessionId,
            hostDeviceId: hostDeviceId,
            actorId: actorId,
            actorType: .human,
            displayName: displayName
        )
    }

    private func addAgentParticipant(sessionId: String, hostDeviceId: String, agentId: String) async throws {
        try await addParticipant(
            sessionId: sessionId,
            hostDeviceId: hostDeviceId,
            actorId: agentId,
            actorType: .personalAgent,
            displayName: agentId
        )
    }

    private func addParticipant(
        sessionId: String,
        hostDeviceId: String,
        actorId: String,
        actorType: Teamclaw_ActorType,
        displayName: String
    ) async throws {
        var participant = Teamclaw_Participant()
        participant.actorID = actorId
        participant.actorType = actorType
        participant.displayName = displayName
        participant.joinedAt = Int64(Date().timeIntervalSince1970)

        var req = Teamclaw_AddParticipantRequest()
        req.sessionID = sessionId
        req.participant = participant

        var rpcReq = Teamclaw_RpcRequest()
        rpcReq.requestID = String(UUID().uuidString.prefix(8)).lowercased()
        rpcReq.senderDeviceID = deviceId
        rpcReq.method = .addParticipant(req)

        guard let data = try? rpcReq.serializedData() else {
            throw SessionCreationError.rpc("Failed to encode participant request")
        }

        let responseTopic = "teamclaw/\(Self.teamId)/rpc/\(deviceId)/+/res"
        try? await mqtt.subscribe(responseTopic)
        // Install the stream before publish to avoid missing an immediate host
        // response on the same broker connection.
        let stream = mqtt.messages()
        try await mqtt.publish(
            topic: "teamclaw/\(Self.teamId)/rpc/\(hostDeviceId)/\(rpcReq.requestID)/req",
            payload: data,
            retain: false
        )

        let deadline = Date().addingTimeInterval(10)
        for await msg in stream {
            if Date() > deadline {
                throw SessionCreationError.rpc("Participant update timed out")
            }
            guard msg.topic.contains("/rpc/"),
                  msg.topic.hasSuffix("/res"),
                  let response = try? Teamclaw_RpcResponse(serializedBytes: msg.payload),
                  response.requestID == rpcReq.requestID else {
                continue
            }
            if !response.success {
                throw SessionCreationError.rpc(response.error.isEmpty ? "Participant update failed" : response.error)
            }
            return
        }

        throw SessionCreationError.rpc("Participant update timed out")
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
