import SwiftUI
import SwiftData
import AMUXCore
import AMUXSharedUI

struct SessionDetailView: View {
    let session: Session
    let teamclawService: TeamclawService
    let actorId: String
    let mqtt: MQTTService?
    let deviceId: String
    let peerId: String

    @Environment(\.modelContext) private var modelContext

    @Query private var allMessages: [SessionMessage]
    @Query private var allAgents: [Agent]
    @Query private var allWorkspaces: [Workspace]

    @State private var searchText: String = ""
    @State private var isPinned: Bool = false
    @State private var agentVM: AgentDetailViewModel?

    private var primaryAgent: Agent? {
        guard let id = session.primaryAgentId else { return nil }
        return allAgents.first(where: { $0.agentId == id })
    }

    private var workspaceName: String? {
        guard let agent = primaryAgent,
              let ws = allWorkspaces.first(where: { $0.workspaceId == agent.workspaceId })
        else { return nil }
        return ws.displayName.isEmpty ? nil : ws.displayName
    }

    private var agentLogoName: String? {
        guard let type = primaryAgent?.agentType else { return nil }
        switch type {
        case 1: return "ClaudeLogo"
        case 2: return "OpenCodeLogo"
        case 3: return "CodexLogo"
        default: return nil
        }
    }

    private var lastUpdated: Date {
        session.lastMessageAt ?? session.createdAt
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let vm = agentVM, primaryAgent != nil {
                        agentEventFeed(vm: vm)
                            .observesPermissionNotifications(agentVM: vm, sessionId: session.sessionId)
                    } else {
                        collabMessageFeed
                    }
                }
                .padding(.top, 12)
            }

            ComposerView(
                teamclawService: teamclawService,
                sessionId: session.sessionId,
                actorId: actorId,
                agent: primaryAgent,
                agentVM: agentVM
            )
        }
        .navigationTitle(session.title.isEmpty ? "Session" : session.title)
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search messages")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isPinned.toggle()
                } label: {
                    Label("Pin", systemImage: isPinned ? "pin.fill" : "pin")
                }
                .help("Pin")
            }
            ToolbarItem(placement: .primaryAction) {
                Button(action: {}) {
                    Label("Archive", systemImage: "archivebox")
                }
                .disabled(true)
                .help("Archive")
            }
            ToolbarItem(placement: .primaryAction) {
                Button(action: {}) {
                    Label("Add member", systemImage: "person.badge.plus")
                }
                .disabled(true)
                .help("Add member")
            }
            ToolbarItem(placement: .primaryAction) {
                Button(action: {}) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .disabled(true)
                .help("Share")
            }
            if agentVM != nil {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        guard let vm = agentVM, !vm.isSyncing else { return }
                        let ctx = modelContext
                        Task { try? await vm.requestIncrementalSync(modelContext: ctx) }
                    } label: {
                        Label(
                            (agentVM?.isSyncing == true) ? "Syncing history…" : "Sync history",
                            systemImage: (agentVM?.isSyncing == true)
                                ? "arrow.triangle.2.circlepath.circle.fill"
                                : "arrow.triangle.2.circlepath"
                        )
                    }
                    .disabled(agentVM?.isSyncing == true)
                    .help((agentVM?.isSyncing == true) ? "Syncing history…" : "Sync history")
                }
            }
        }
        .task(id: session.sessionId) {
            teamclawService.subscribeToSession(session.sessionId)
        }
        .task(id: agentTaskId) {
            startAgentVMIfNeeded()
        }
        .onDisappear { agentVM?.stop(); agentVM = nil }
    }

    /// Identity string used to re-trigger the agent-VM task when the session's
    /// primary agent changes, or when MQTT becomes available.
    private var agentTaskId: String {
        "\(session.primaryAgentId ?? "none")#\(mqtt == nil ? "no-mqtt" : "mqtt")"
    }

    @MainActor
    private func startAgentVMIfNeeded() {
        agentVM?.stop()
        guard let agent = primaryAgent, let mqtt else {
            agentVM = nil
            return
        }
        let vm = AgentDetailViewModel(
            agent: agent,
            mqtt: mqtt,
            deviceId: deviceId,
            peerId: peerId,
            session: session,
            teamclawService: teamclawService
        )
        vm.start(modelContext: modelContext)
        agentVM = vm
    }

    @ViewBuilder
    private func agentEventFeed(vm: AgentDetailViewModel) -> some View {
        let filtered: [AgentEvent] = {
            if searchText.isEmpty { return vm.events }
            let q = searchText
            return vm.events.filter { ($0.text ?? "").localizedCaseInsensitiveContains(q) }
        }()

        if filtered.isEmpty && !vm.isStreaming {
            Text(searchText.isEmpty ? "No activity yet." : "No events match \u{201C}\(searchText)\u{201D}.")
                .foregroundStyle(.tertiary)
                .padding(22)
        } else {
            // Collapse long runs of consecutive completed tools into a single
            // expandable summary bar, same as iOS AMUXUI.
            ForEach(groupEvents(filtered)) { group in
                switch group {
                case .single(let event):
                    AgentEventRow(
                        event: event,
                        agent: primaryAgent,
                        onGrant: { id in Task { try? await vm.grantPermission(requestId: id) } },
                        onDeny:  { id in Task { try? await vm.denyPermission(requestId: id) } }
                    )
                case .toolRun(_, let events):
                    ToolRunSummaryBar(events: events)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 2)
                }
            }
            if vm.isStreaming && !vm.streamingText.isEmpty {
                MarkdownRenderer(content: vm.streamingText)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .padding(.horizontal, 16)
            }
            if vm.isActive {
                AgentTypingIndicator()
                    .padding(.horizontal, 16)
                    .padding(.vertical, 4)
            }
        }
    }

    @ViewBuilder
    private var collabMessageFeed: some View {
        let messages = allMessages
            .filter { $0.sessionId == session.sessionId }
            .filter { searchText.isEmpty || $0.content.localizedCaseInsensitiveContains(searchText) }
            .sorted { $0.createdAt < $1.createdAt }

        if messages.isEmpty {
            Text(searchText.isEmpty ? "No messages yet." : "No messages match \u{201C}\(searchText)\u{201D}.")
                .foregroundStyle(.tertiary)
                .padding(22)
        } else {
            ForEach(messages, id: \.messageId) { message in
                rowView(for: message)
            }
            .padding(.bottom, 22)
        }
    }

    // Mirrors SessionRow.formatTime — duplicated here to keep the header
    // self-contained. If a third copy lands somewhere, lift this into a
    // shared helper.
    static func formatTime(_ date: Date) -> String {
        let seconds = Int(-date.timeIntervalSinceNow)
        if seconds < 60 { return "Just now" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        if seconds < 86400 { return "\(seconds / 3600)h" }
        if seconds < 604800 { return "\(seconds / 86400)d" }
        let formatter = DateFormatter()
        formatter.dateFormat = "MM/dd"
        return formatter.string(from: date)
    }

    // MARK: - Message rows

    private func senderName(for actorId: String) -> String {
        actorId.isEmpty ? "Agent" : actorId
    }

    @ViewBuilder
    private func rowView(for message: SessionMessage) -> some View {
        if message.isSystem {
            MessageRowSystem(message: message)
        } else if message.senderActorId == actorId {
            MessageRowUser(message: message, senderName: senderName(for: message.senderActorId))
        } else {
            MessageRowAgent(
                message: message,
                senderName: senderName(for: message.senderActorId),
                modelLabel: modelLabel(for: message)
            )
        }
    }

    private var modelLookup: [String: String] {
        guard let agent = primaryAgent else { return [:] }
        return Dictionary(uniqueKeysWithValues: agent.availableModels.map { ($0.id, $0.displayName) })
    }

    private func modelLabel(for message: SessionMessage) -> String? {
        guard let modelId = message.model, !modelId.isEmpty else { return nil }
        return modelLookup[modelId] ?? modelId
    }
}

private struct AgentTypingIndicator: View {
    @State private var phase: Double = 0

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Color.secondary)
                    .frame(width: 7, height: 7)
                    .scaleEffect(dotScale(for: i))
                    .opacity(dotOpacity(for: i))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                phase = 1
            }
        }
    }

    private func dotScale(for index: Int) -> Double {
        let offset = Double(index) * 0.15
        let value = sin((phase + offset) * .pi)
        return 0.6 + 0.4 * value
    }

    private func dotOpacity(for index: Int) -> Double {
        let offset = Double(index) * 0.15
        let value = sin((phase + offset) * .pi)
        return 0.4 + 0.6 * value
    }
}
