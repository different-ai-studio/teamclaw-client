import SwiftUI
import SwiftData
import AMUXCore

#if os(iOS)

private enum ActorDirectoryEntry: Identifiable {
    case member(Member)
    case agent(Agent)

    var id: String {
        switch self {
        case .member(let member): return "member:\(member.memberId)"
        case .agent(let agent): return "agent:\(agent.agentId)"
        }
    }

    var sortName: String {
        switch self {
        case .member(let member): return member.displayName
        case .agent(let agent): return actorDisplayName(for: agent)
        }
    }
}

/// Browse-mode actor list body. No NavigationStack; parent provides it.
/// Used as the pushable content in MembersTab.
public struct MemberListContent: View {
    @State private var viewModel = MemberListViewModel()
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Agent.sessionTitle) private var allAgents: [Agent]
    let mqtt: MQTTService
    let deviceId: String
    let peerId: String
    let sessionViewModel: SessionListViewModel

    public init(mqtt: MQTTService,
                deviceId: String,
                peerId: String,
                sessionViewModel: SessionListViewModel) {
        self.mqtt = mqtt
        self.deviceId = deviceId
        self.peerId = peerId
        self.sessionViewModel = sessionViewModel
    }

    private var actors: [ActorDirectoryEntry] {
        (viewModel.members.map(ActorDirectoryEntry.member) + allAgents.map(ActorDirectoryEntry.agent))
            .sorted { lhs, rhs in
                lhs.sortName.localizedCaseInsensitiveCompare(rhs.sortName) == .orderedAscending
            }
    }

    public var body: some View {
        List {
            ForEach(actors) { actor in
                NavigationLink {
                    ActorDetailView(actor: actor,
                                    mqtt: mqtt,
                                    deviceId: deviceId,
                                    peerId: peerId,
                                    sessionViewModel: sessionViewModel,
                                    memberViewModel: viewModel)
                } label: {
                    ActorRow(actor: actor, onlineMemberIds: viewModel.onlineMemberIds)
                }
            }
        }
        .task { viewModel.start(mqtt: mqtt, deviceId: deviceId, modelContext: modelContext) }
    }
}
#else
struct MemberListContent: View {
    var body: some View {
        ContentUnavailableView("Actors", systemImage: "person.2")
    }
}
#endif

private struct ActorRow: View {
    let actor: ActorDirectoryEntry
    let onlineMemberIds: Set<String>

    var body: some View {
        HStack {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body)
                HStack(spacing: 6) {
                    Text(primaryMeta)
                    if let secondaryMeta {
                        Text("·").foregroundStyle(.tertiary)
                        Text(secondaryMeta)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Text("0 sessions")
                .font(.caption)
                .foregroundStyle(.tertiary)
            if crownVisible {
                Image(systemName: "crown.fill").foregroundStyle(.orange).font(.caption)
            }
        }
    }

    private var title: String {
        switch actor {
        case .member(let member): return member.displayName
        case .agent(let agent): return actorDisplayName(for: agent)
        }
    }

    private var primaryMeta: String {
        switch actor {
        case .member(let member): return member.roleLabel
        case .agent: return "Digital Employee"
        }
    }

    private var secondaryMeta: String? {
        switch actor {
        case .member(let member):
            let label = departmentLabel(for: member)
            return label == "—" ? nil : label
        case .agent(let agent):
            return agent.agentTypeLabel
        }
    }

    private var crownVisible: Bool {
        if case .member(let member) = actor { return member.isOwner }
        return false
    }

    private var statusColor: Color {
        switch actor {
        case .member(let member):
            return onlineMemberIds.contains(member.memberId) ? .green : .secondary.opacity(0.4)
        case .agent(let agent):
            switch agent.status {
            case 2: return .green
            case 3: return .yellow
            case 4, 5: return .red
            default: return .secondary.opacity(0.4)
            }
        }
    }
}

private func departmentLabel(for member: Member) -> String {
    if let dept = member.department, !dept.isEmpty { return dept }
    return "—"
}

private struct ActorDetailView: View {
    let actor: ActorDirectoryEntry
    let mqtt: MQTTService
    let deviceId: String
    let peerId: String
    let sessionViewModel: SessionListViewModel
    let memberViewModel: MemberListViewModel

    @Query private var allMessages: [SessionMessage]
    @Query(sort: \Session.lastMessageAt, order: .reverse)
    private var allSessions: [Session]

    @State private var showNewSession = false

    private var title: String {
        switch actor {
        case .member(let member): return member.displayName
        case .agent(let agent): return actorDisplayName(for: agent)
        }
    }

    private var actorId: String {
        switch actor {
        case .member(let member): return member.memberId
        case .agent(let agent): return agent.agentId
        }
    }

    private var actorSessions: [Session] {
        let sessionIds = Set(
            allMessages
                .filter { $0.senderActorId == actorId }
                .map(\.sessionId)
        )
        let messageSessions = allSessions.filter { sessionIds.contains($0.sessionId) }
        switch actor {
        case .member:
            return messageSessions
        case .agent(let agent):
            let primarySessions = allSessions.filter { $0.primaryAgentId == agent.agentId }
            return Array(Dictionary(uniqueKeysWithValues: (messageSessions + primarySessions).map { ($0.sessionId, $0) }).values)
                .sorted { lhs, rhs in
                    (lhs.lastMessageAt ?? lhs.createdAt) > (rhs.lastMessageAt ?? rhs.createdAt)
                }
        }
    }

    var body: some View {
        List {
            Section("Info") {
                switch actor {
                case .member(let member):
                    LabeledContent("Name") {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(memberViewModel.isOnline(member) ? Color.green : Color.secondary.opacity(0.4))
                                .frame(width: 8, height: 8)
                            Text(member.displayName)
                        }
                    }
                    LabeledContent("Kind", value: "Human")
                    LabeledContent("Status", value: memberViewModel.isOnline(member) ? "Online" : "Offline")
                    LabeledContent("Role", value: member.roleLabel)
                    LabeledContent("Department", value: departmentLabel(for: member))
                    LabeledContent("Joined", value: member.joinedAt.formatted(date: .abbreviated, time: .shortened))
                case .agent(let agent):
                    LabeledContent("Name", value: actorDisplayName(for: agent))
                    LabeledContent("Kind", value: "Digital Employee")
                    LabeledContent("Status", value: agent.statusLabel)
                    LabeledContent("Backend", value: agent.agentTypeLabel)
                    LabeledContent("Workspace", value: agent.workspaceId.isEmpty ? "—" : agent.workspaceId)
                    if let model = agent.currentModel, !model.isEmpty {
                        LabeledContent("Model", value: model)
                    }
                }
            }
            Section("Collab Sessions") {
                if actorSessions.isEmpty {
                    Text("No sessions yet")
                        .font(.body)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(actorSessions, id: \.sessionId) { session in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(session.title.isEmpty ? "(untitled)" : session.title)
                                .font(.body)
                            if let last = session.lastMessageAt {
                                Text(last.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            Section("ID") {
                Text(actorId)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            if case .member(let member) = actor {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showNewSession = true
                    } label: {
                        Image(systemName: "bubble.left.and.bubble.right")
                            .font(.title3)
                            .foregroundStyle(.primary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("New session")
                }
            }
        }
        .sheet(isPresented: $showNewSession) {
            if case .member(let member) = actor {
                NewSessionSheet(
                    mqtt: mqtt,
                    deviceId: deviceId,
                    peerId: peerId,
                    viewModel: sessionViewModel,
                    preselectedCollaborators: [member]
                )
            }
        }
    }
}

private func actorDisplayName(for agent: Agent) -> String {
    if !agent.sessionTitle.isEmpty { return agent.sessionTitle }
    return agent.agentId
}
