import SwiftUI
import SwiftData
import AMUXCore

// MARK: - NewSessionSheet (macOS)
//
// macOS port of the iOS NewSessionSheet. Uses @Query for workspaces directly
// instead of a SessionListViewModel — macOS doesn't have one yet, and reading
// SwiftData here is the lighter-weight choice.
//
// v1 skips the collaborator picker (the iOS MemberListView hasn't been ported
// to macOS). Single-host sessions only — collab dispatch via CreateSessionRequest
// will land in v1.1.

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
    @State private var messageText: String = ""
    @State private var isSending = false
    @State private var errorMessage: String?
    @FocusState private var isInputFocused: Bool

    private var canSend: Bool {
        selectedWorkspaceId != nil &&
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

    // MARK: - Collaborators (deferred to v1.1)

    private var collaboratorsRow: some View {
        HStack(alignment: .center, spacing: 8) {
            Text("Collaborators")
                .foregroundStyle(.secondary)

            Text("Solo session")
                .font(.subheadline)
                .foregroundStyle(.tertiary)

            Spacer(minLength: 0)

            // TODO(v1.1): port iOS MemberListView and enable collaborator picking.
            Button {} label: {
                Image(systemName: "plus.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(true)
            .help("Collaborator picker coming in v1.1")
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
        guard !text.isEmpty, let workspaceId = selectedWorkspaceId else { return }

        isInputFocused = false
        errorMessage = nil
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
}
