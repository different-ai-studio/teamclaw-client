import SwiftUI
import SwiftData
import AMUXCore
import AMUXSharedUI

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
    // Workspaces are passed in from MainWindowView. A prior attempt used
    // @Query directly here, but the sheet's separate NSWindow doesn't reliably
    // inherit the parent's modelContainer, and adding `.modelContainer(...)`
    // to the sheet triggered a window-scene rebuild that wiped column 2's
    // toolbar items. Taking the rows as a plain parameter avoids both issues.
    let workspaces: [Workspace]
    let preselectedTaskId: String?
    var onSessionCreated: ((String) -> Void)?

    @State private var selectedWorkspaceId: String?
    @State private var selectedAgentType: Amux_AgentType = .claudeCode
    @State private var collaborators: [Member] = []
    @State private var selectedTaskId: String?
    @State private var showMemberPicker = false
    @State private var messageText: String = ""
    @State private var isSending = false
    @State private var errorMessage: String?
    @State private var voice = VoiceRecorder()
    @FocusState private var isInputFocused: Bool
    @Query(filter: #Predicate<SessionTask> { !$0.archived },
           sort: \SessionTask.createdAt, order: .reverse)
    private var tasks: [SessionTask]

    /// Matches daemon.toml `team_id`. Must be kept in sync with the daemon config.
    private static let teamId = "teamclaw"

    private var canSend: Bool {
        // Shared sessions don't require a workspace — the daemon binds the
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
                workspaceRow
                Divider()
                collaboratorsRow
                Divider()
                taskRow
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
        .frame(minWidth: 600, idealWidth: 640, minHeight: 380, idealHeight: 440)
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
            if selectedTaskId == nil, let preselectedTaskId {
                selectedTaskId = preselectedTaskId
                if let task = tasks.first(where: { $0.taskId == preselectedTaskId }),
                   !task.workspaceId.isEmpty {
                    selectedWorkspaceId = task.workspaceId
                }
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
        .onChange(of: voice.transcript) { _, newValue in
            if voice.state == .recording, !newValue.isEmpty {
                messageText = newValue
            }
        }
        .onKeyPress(.escape) {
            if voice.state == .recording {
                voice.cancel()
                return .handled
            }
            return .ignored
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("New Session")
                .font(.title2)
                .fontWeight(.bold)
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    // MARK: - Workspace

    private var workspaceRow: some View {
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

    // MARK: - Task

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
                            Label(
                                item.displayTitle,
                                systemImage: selectedTaskId == item.taskId ? "checkmark" : "circle"
                            )
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
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
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
        ZStack(alignment: .bottomLeading) {
            TextField("Initial prompt…", text: $messageText, axis: .vertical)
                .textFieldStyle(.plain)
                .focused($isInputFocused)
                .font(.system(size: 13))
                .lineLimit(2...6)
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 46)
                .padding(.trailing, 88)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(alignment: .bottom, spacing: 10) {
                HStack(spacing: 8) {
                    attachmentButton
                    agentTypePicker
                }

                Spacer()

                HStack(spacing: 10) {
                    voiceButton
                    sendButton
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
        }
        .frame(minHeight: 96, maxHeight: 186)
        .glassEffect(in: Rectangle())
    }

    // MARK: - Send

    /// If a task is selected, prefix its context into the first message so the
    /// new session starts with the chosen task's title/description.
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
        let text = firstMessageText(userText: userText)

        isInputFocused = false
        errorMessage = nil

        if !collaborators.isEmpty || selectedTaskId != nil {
            createSharedSession(text: text)
            return
        }

        guard let workspaceId = selectedWorkspaceId else { return }

        isSending = true

        Task {
            // Per-agent retained state topic replaces the old bulk AgentList;
            // we now watch `agent/{id}/state` publishes to detect our new
            // session by matching the prompt.
            let stream = mqtt.messages()
            let agentStatePrefix = "amux/\(deviceId)/agent/"
            let agentStateSuffix = "/state"
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

            // Wait up to 15s for the new agent's state publish or a rejection.
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

                if msg.topic.hasPrefix(agentStatePrefix),
                   msg.topic.hasSuffix(agentStateSuffix),
                   !msg.payload.isEmpty,
                   let info = try? ProtoMQTTCoder.decode(Amux_AgentInfo.self, from: msg.payload),
                   info.currentPrompt == text {
                    let agentId = info.agentID
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

    private var attachmentButton: some View {
        Button(action: {}) {
            Image(systemName: "paperclip")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
        }
        .buttonStyle(.plain)
        .glassEffect(in: Circle())
        .disabled(true)
        .help("Attachments are not available yet")
    }

    private var agentTypePicker: some View {
        Menu {
            Button {
                selectedAgentType = .claudeCode
            } label: {
                if selectedAgentType == .claudeCode {
                    Label("Claude", systemImage: "checkmark")
                } else {
                    Text("Claude")
                }
            }
            Button {
                selectedAgentType = .opencode
            } label: {
                if selectedAgentType == .opencode {
                    Label("OpenCode", systemImage: "checkmark")
                } else {
                    Text("OpenCode")
                }
            }
            Button {
                selectedAgentType = .codex
            } label: {
                if selectedAgentType == .codex {
                    Label("Codex", systemImage: "checkmark")
                } else {
                    Text("Codex")
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "cpu")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text(selectedAgentTypeLabel)
                    .font(.system(size: 12))
                Image(systemName: "chevron.down")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .glassEffect(in: Capsule())
            .foregroundStyle(.primary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var voiceButton: some View {
        Button {
            voice.toggle()
        } label: {
            Image(systemName: voice.state == .recording ? "mic.fill" : "mic")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(voice.state == .recording ? .red : .primary)
                .frame(width: 34, height: 34)
        }
        .buttonStyle(.plain)
        .glassEffect(in: Circle())
        .help(voice.state == .recording ? "Stop recording (Esc to cancel)" : "Voice input")
    }

    private var sendButton: some View {
        Button(action: sendAndCreate) {
            Image(systemName: "arrow.up")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(canSend ? Color.white : .secondary)
                .frame(width: 34, height: 34)
                .background(canSend ? Color.accentColor : Color.white.opacity(0.42), in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(!canSend)
        .keyboardShortcut(.return, modifiers: .command)
        .help("Start session")
    }

    private var selectedAgentTypeLabel: String {
        switch selectedAgentType {
        case .claudeCode:
            "Claude"
        case .opencode:
            "OpenCode"
        case .codex:
            "Codex"
        default:
            "Agent"
        }
    }

    // MARK: - Shared Session (Teamclaw CreateSessionRequest RPC)
    //
    // Mirrors iOS NewSessionSheet.createSharedSession. The daemon listens on
    // teamclaw/{teamId}/rpc/{deviceId}/{requestId}/req and replies on the
    // matching /res topic with a Teamclaw_RpcResponse.

    private func createSharedSession(text: String) {
        isSending = true

        var createReq = Teamclaw_CreateSessionRequest()
        createReq.sessionType = .collab
        createReq.teamID = Self.teamId
        createReq.title = String(text.prefix(50)).trimmingCharacters(in: .whitespacesAndNewlines)
        createReq.summary = text
        createReq.inviteActorIds = collaborators.map(\.memberId)
        if let taskId = selectedTaskId, !taskId.isEmpty {
            createReq.taskID = taskId
        }

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
                        let session = Session(
                            sessionId: info.sessionID,
                            mode: "collab",
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
                        onSessionCreated?(info.sessionID)
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
