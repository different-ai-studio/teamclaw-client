import SwiftUI
import SwiftData
import AMUXCore

// MARK: - NewSessionSheet (macOS)
//
// macOS port of the iOS NewSessionSheet. Uses @Query for workspaces directly
// instead of a SessionListViewModel — macOS doesn't have one yet, and reading
// SwiftData here is the lighter-weight choice.
//
// Behavior mirrors iOS: when `collaborators` is empty we start a solo agent
// via Amux_AcpStartAgent; when non-empty we issue a Teamclaw_CreateSessionRequest
// RPC to the daemon, which returns a SessionInfo we insert into SwiftData.

struct NewSessionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let mqtt: MQTTService
    let deviceId: String
    let peerId: String
    var onSessionCreated: ((String) -> Void)?

    @Query(sort: \Workspace.displayName) private var workspaces: [Workspace]

    @State private var selectedWorkspaceId: String?
    @State private var selectedAgentType: Amux_AgentType = .claudeCode
    @State private var collaborators: [Member] = []
    @State private var showMemberPicker = false
    @State private var messageText: String = ""
    @State private var isSending = false
    @State private var errorMessage: String?
    @FocusState private var isInputFocused: Bool

    /// Matches daemon.toml `team_id`. Must be kept in sync with the daemon config.
    private static let teamId = "teamclaw"

    private var canSend: Bool {
        // Collab sessions don't require a workspace — the daemon binds the
        // primary agent later from the host's workspace.
        let workspaceOK = selectedWorkspaceId != nil || !collaborators.isEmpty
        return workspaceOK &&
            !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !isSending
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                header
                Divider()
                workspaceAndTypeRow
                Divider()
                collaboratorsRow
                Divider()
                Spacer(minLength: 8)
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
                ProgressView("Starting session\u{2026}")
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .frame(minWidth: 520, idealWidth: 560, minHeight: 360, idealHeight: 420)
        .background(Color(NSColor.windowBackgroundColor))
        .allowsHitTesting(!isSending)
        .sheet(isPresented: $showMemberPicker) {
            MemberPickerSheet(
                mqtt: mqtt,
                deviceId: deviceId,
                selected: Set(collaborators.map(\.memberId))
            ) { picked in
                collaborators = picked
            }
        }
        .onAppear {
            isInputFocused = true
            if workspaces.count == 1 {
                selectedWorkspaceId = workspaces.first?.workspaceId
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("New Session")
                .font(.title2)
                .fontWeight(.bold)
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .background(Color.secondary.opacity(0.12), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    // MARK: - Workspace & Agent Type

    private var workspaceAndTypeRow: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Workspace")
                    .foregroundStyle(.secondary)
                Spacer()
                Menu {
                    if workspaces.isEmpty {
                        Text("No workspaces")
                    } else {
                        ForEach(workspaces, id: \.workspaceId) { ws in
                            Button {
                                selectedWorkspaceId = ws.workspaceId
                            } label: {
                                Label(
                                    ws.displayName,
                                    systemImage: selectedWorkspaceId == ws.workspaceId ? "checkmark" : "folder"
                                )
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
                .menuStyle(.borderlessButton)
                .fixedSize()
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
                .labelsHidden()
                .frame(maxWidth: 280)
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

    // MARK: - Collaborators

    private var collaboratorsRow: some View {
        HStack(alignment: .center, spacing: 8) {
            Text("Collaborators")
                .foregroundStyle(.secondary)

            if collaborators.isEmpty {
                Text("Solo session")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
            } else {
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
            }

            Spacer(minLength: 0)

            Button {
                isInputFocused = false
                showMemberPicker = true
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            .help("Add collaborators")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Input bar

    private var inputBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Initial prompt\u{2026}", text: $messageText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .focused($isInputFocused)
                    .lineLimit(1...8)
                    .font(.body)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))

                Button(action: sendAndCreate) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(canSend ? Color.accentColor : .secondary.opacity(0.5))
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.regularMaterial)
        }
    }

    // MARK: - Send

    private func sendAndCreate() {
        let text = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        isInputFocused = false
        errorMessage = nil

        if !collaborators.isEmpty {
            createCollabSession(text: text)
            return
        }

        guard let workspaceId = selectedWorkspaceId else { return }

        isSending = true

        Task {
            let stream = mqtt.messages()
            let agentsTopic = "amux/\(deviceId)/agents"
            let collabTopic = "amux/\(deviceId)/collab"

            var cmd = Amux_CommandEnvelope()
            cmd.agentID = ""
            cmd.deviceID = deviceId
            cmd.peerID = peerId
            cmd.commandID = UUID().uuidString
            cmd.timestamp = Int64(Date().timeIntervalSince1970)
            var start = Amux_AcpStartAgent()
            start.agentType = selectedAgentType
            start.workspaceID = workspaceId
            start.worktree = ""
            start.initialPrompt = text
            var acpCmd = Amux_AcpCommand()
            acpCmd.command = .startAgent(start)
            cmd.acpCommand = acpCmd

            do {
                let data = try ProtoMQTTCoder.encode(cmd)
                try await mqtt.publish(topic: "amux/\(deviceId)/agent/new/commands", payload: data)
            } catch {
                await MainActor.run {
                    isSending = false
                    errorMessage = "Failed to send: \(error.localizedDescription)"
                }
                return
            }

            // Wait up to 15s for agent list update or rejection
            let deadline = Date().addingTimeInterval(15)
            for await msg in stream {
                if Date() > deadline { break }

                if msg.topic == collabTopic,
                   let dce = try? ProtoMQTTCoder.decode(Amux_DeviceCollabEvent.self, from: msg.payload),
                   !dce.commandRejected.reason.isEmpty {
                    await MainActor.run {
                        isSending = false
                        errorMessage = dce.commandRejected.reason
                    }
                    return
                }

                if msg.topic == agentsTopic,
                   let list = try? ProtoMQTTCoder.decode(Amux_AgentList.self, from: msg.payload),
                   let newAgent = list.agents.first(where: { $0.currentPrompt == text }) {
                    let agentId = newAgent.agentID
                    await MainActor.run {
                        isSending = false
                        onSessionCreated?(agentId)
                        dismiss()
                    }
                    return
                }
            }

            await MainActor.run {
                isSending = false
                errorMessage = "Session creation timed out. Check daemon logs."
            }
        }
    }

    // MARK: - Collab session (Teamclaw CreateSessionRequest RPC)
    //
    // Mirrors iOS NewSessionSheet.createCollabSession. The daemon listens on
    // teamclaw/{teamId}/rpc/{deviceId}/{requestId}/req and replies on the
    // matching /res topic with a Teamclaw_RpcResponse.

    private func createCollabSession(text: String) {
        isSending = true

        var createReq = Teamclaw_CreateSessionRequest()
        createReq.sessionType = .collab
        createReq.teamID = Self.teamId
        createReq.title = String(text.prefix(50)).trimmingCharacters(in: .whitespacesAndNewlines)
        createReq.summary = text
        createReq.inviteActorIds = collaborators.map(\.memberId)

        var rpcReq = Teamclaw_RpcRequest()
        rpcReq.requestID = String(UUID().uuidString.prefix(8)).lowercased()
        rpcReq.senderDeviceID = deviceId
        rpcReq.method = .createSession(createReq)

        let requestId = rpcReq.requestID
        let topic = "teamclaw/\(Self.teamId)/rpc/\(deviceId)/\(requestId)/req"
        let responseTopic = "teamclaw/\(Self.teamId)/rpc/\(deviceId)/+/res"

        Task {
            try? await mqtt.subscribe(responseTopic)
            let stream = mqtt.messages()

            guard let data = try? rpcReq.serializedData() else {
                await MainActor.run {
                    isSending = false
                    errorMessage = "Failed to encode request"
                }
                return
            }
            try? await mqtt.publish(topic: topic, payload: data, retain: false)

            let deadline = Date().addingTimeInterval(10)
            for await msg in stream {
                if Date() > deadline { break }
                guard msg.topic.contains("/rpc/"), msg.topic.hasSuffix("/res") else { continue }
                guard let response = try? Teamclaw_RpcResponse(serializedBytes: msg.payload) else { continue }

                if response.success, case .sessionInfo(let info) = response.result {
                    await MainActor.run {
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
                        session.primaryAgentId = info.primaryAgentID.isEmpty ? nil : info.primaryAgentID
                        modelContext.insert(session)
                        try? modelContext.save()

                        isSending = false
                        onSessionCreated?("collab:\(info.sessionID)")
                        dismiss()
                    }
                    return
                } else if !response.error.isEmpty {
                    await MainActor.run {
                        isSending = false
                        errorMessage = response.error
                    }
                    return
                }
            }

            await MainActor.run {
                isSending = false
                errorMessage = "Session creation timed out"
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
            .buttonStyle(.plain)
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .padding(.vertical, 5)
        .foregroundStyle(.primary)
        .background(Color.secondary.opacity(0.15), in: Capsule())
    }
}
