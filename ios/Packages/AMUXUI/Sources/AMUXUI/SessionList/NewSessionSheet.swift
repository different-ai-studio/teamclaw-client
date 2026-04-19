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

    let viewModel: SessionListViewModel
    let preselectedWorkItemId: String?
    let preselectedCollaborators: [Member]
    @State private var selectedWorkspaceId: String?
    @State private var selectedAgentType: Amux_AgentType = .claudeCode

    @State private var collaborators: [Member] = []
    @State private var selectedWorkItemId: String?
    @State private var messageText: String = ""
    @State private var showMemberPicker = false
    @State private var isSending = false
    @State private var errorMessage: String?
    @FocusState private var isInputFocused: Bool

    @Query(filter: #Predicate<WorkItem> { !$0.archived },
           sort: \WorkItem.createdAt, order: .reverse)
    private var workItems: [WorkItem]

    private var workspaces: [Workspace] { viewModel.workspaces }

    /// Set by parent — called with agentId when session is created
    var onSessionCreated: ((String) -> Void)?

    public init(mqtt: MQTTService, deviceId: String, peerId: String, viewModel: SessionListViewModel,
                preselectedWorkItemId: String? = nil,
                preselectedCollaborators: [Member] = [],
                onSessionCreated: ((String) -> Void)? = nil) {
        self.mqtt = mqtt
        self.deviceId = deviceId
        self.peerId = peerId
        self.viewModel = viewModel
        self.preselectedWorkItemId = preselectedWorkItemId
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
            if selectedWorkItemId == nil, let preselectedWorkItemId {
                selectedWorkItemId = preselectedWorkItemId
            }
            if collaborators.isEmpty, !preselectedCollaborators.isEmpty {
                collaborators = preselectedCollaborators
            }
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
                    selectedWorkItemId = nil
                } label: {
                    Label("None", systemImage: selectedWorkItemId == nil ? "checkmark" : "circle")
                }
                if !workItems.isEmpty {
                    Divider()
                    ForEach(workItems, id: \.workItemId) { item in
                        Button {
                            selectedWorkItemId = item.workItemId
                        } label: {
                            Label(item.displayTitle,
                                  systemImage: selectedWorkItemId == item.workItemId ? "checkmark" : "circle")
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
                .foregroundStyle(selectedWorkItemId == nil ? .secondary : .primary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var selectedTaskLabel: String {
        if let id = selectedWorkItemId,
           let item = workItems.first(where: { $0.workItemId == id }) {
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
        guard let id = selectedWorkItemId,
              let item = workItems.first(where: { $0.workItemId == id }) else {
            return userText
        }
        let description = item.itemDescription.trimmingCharacters(in: .whitespacesAndNewlines)
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

        // Collab path also handles the case where a task was picked but no
        // collaborators were added — ACP startAgent has no workItemId field,
        // so task linking must flow through CreateSessionRequest.
        if !collaborators.isEmpty || selectedWorkItemId != nil {
            createCollabSession(text: text)
            return
        }

        isSending = true

        Task {
            // Listen for agent list updates before sending
            let stream = mqtt.messages()
            let agentsTopic = "amux/\(deviceId)/agents"

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
            start.initialPrompt = text
            var acpCmd = Amux_AcpCommand()
            acpCmd.command = .startAgent(start)
            cmd.acpCommand = acpCmd

            do {
                let data = try ProtoMQTTCoder.encode(cmd)
                try await mqtt.publish(topic: "amux/\(deviceId)/agent/new/commands", payload: data)
            } catch {
                isSending = false
                errorMessage = "Failed to send: \(error.localizedDescription)"
                return
            }

            // Wait up to 15s for agent list update or rejection
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

                // Check for new agent on agents topic
                if msg.topic == agentsTopic {
                    if let list = try? ProtoMQTTCoder.decode(Amux_AgentList.self, from: msg.payload),
                       let newAgent = list.agents.first(where: { $0.currentPrompt == text }) {
                        let agentId = newAgent.agentID
                        isSending = false
                        onSessionCreated?(agentId)
                        dismiss()
                        return
                    }
                }
            }

            // Timeout
            isSending = false
            errorMessage = "Session creation timed out. Check daemon logs."
        }
    }

    /// v1: team_id matches daemon.toml config. Must be kept in sync.
    private static let teamId = "teamclaw"

    private func createCollabSession(text: String) {
        isSending = true

        // Build CreateSessionRequest RPC
        var createReq = Teamclaw_CreateSessionRequest()
        createReq.sessionType = .collab
        createReq.teamID = Self.teamId
        createReq.title = String(text.prefix(50)).trimmingCharacters(in: .whitespacesAndNewlines)
        createReq.summary = text
        createReq.inviteActorIds = collaborators.map(\.memberId)
        if let workItemId = selectedWorkItemId, !workItemId.isEmpty {
            createReq.workItemID = workItemId
        }

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

            // Listen for response
            let stream = mqtt.messages()

            guard let data = try? rpcReq.serializedData() else {
                isSending = false
                errorMessage = "Failed to encode request"
                return
            }
            try? await mqtt.publish(topic: topic, payload: data, retain: false)

            // Wait up to 10s for RPC response
            let deadline = Date().addingTimeInterval(10)
            for await msg in stream {
                if Date() > deadline { break }

                // Match response by requestId in topic
                if msg.topic.contains("/rpc/") && msg.topic.hasSuffix("/res") {
                    if let response = try? Teamclaw_RpcResponse(serializedBytes: msg.payload) {
                        if response.success, case .sessionInfo(let info) = response.result {
                            // Save to SwiftData so navigation can find it
                            let session = CollabSession(
                                sessionId: info.sessionID,
                                sessionType: "collab",
                                teamId: info.teamID,
                                title: info.title,
                                hostDeviceId: info.hostDeviceID,
                                createdBy: info.createdBy,
                                createdAt: Date(timeIntervalSince1970: TimeInterval(info.createdAt)),
                                summary: info.summary,
                                participantCount: info.participants.count
                            )
                            // Host of CreateSession stamps primaryAgentId here. Non-host members
                            // receive it via the daemon's retained /session/{id}/meta envelope,
                            // decoded by TeamclawService.handleIncoming → syncSessionMeta.
                            session.primaryAgentId = info.primaryAgentID.isEmpty ? nil : info.primaryAgentID
                            modelContext.insert(session)
                            try? modelContext.save()
                            // Also refresh the viewModel
                            viewModel.reloadCollabSessions(modelContext: modelContext)

                            isSending = false
                            onSessionCreated?("collab:\(info.sessionID)")
                            dismiss()
                            return
                        } else if !response.error.isEmpty {
                            isSending = false
                            errorMessage = response.error
                            return
                        }
                    }
                }
            }

            // Timeout
            isSending = false
            errorMessage = "Session creation timed out"
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
