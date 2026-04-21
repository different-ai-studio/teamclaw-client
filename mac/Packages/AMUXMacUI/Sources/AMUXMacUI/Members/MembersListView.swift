import SwiftUI
import SwiftData
import AMUXCore

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

/// Mac-native actor list. Not a port of iOS MemberListContent (which has
/// deep iOS-specific navigation chrome); this is a Mac-idiomatic plain list.
struct MembersListView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var viewModel = MemberListViewModel()
    @Query(sort: \Agent.sessionTitle) private var allAgents: [Agent]
    let mqtt: MQTTService?
    let deviceId: String

    private var actors: [ActorDirectoryEntry] {
        (viewModel.members.map(ActorDirectoryEntry.member) + allAgents.map(ActorDirectoryEntry.agent))
            .sorted { lhs, rhs in
                lhs.sortName.localizedCaseInsensitiveCompare(rhs.sortName) == .orderedAscending
            }
    }

    var body: some View {
        VStack(spacing: 0) {
            if actors.isEmpty {
                ContentUnavailableView(
                    "No actors yet",
                    systemImage: "person.2",
                    description: Text("Invite teammates or start agents to see them here.")
                )
            } else {
                List(actors) { actor in
                    ActorRowView(actor: actor, onlineMemberIds: viewModel.onlineMemberIds)
                }
                .listStyle(.inset)
            }
        }
        .task {
            if let mqtt {
                viewModel.start(mqtt: mqtt, deviceId: deviceId, modelContext: modelContext)
            }
        }
    }
}

private struct ActorRowView: View {
    let actor: ActorDirectoryEntry
    let onlineMemberIds: Set<String>

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title).font(.body)
                    if crownVisible {
                        Image(systemName: "crown.fill")
                            .foregroundStyle(.orange)
                            .font(.caption2)
                    }
                }
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
            Text(statusText)
                .font(.caption)
                .foregroundStyle(statusForeground)
        }
        .padding(.vertical, 4)
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
            guard let dept = member.department, !dept.isEmpty else { return nil }
            return dept
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

    private var statusText: String {
        switch actor {
        case .member(let member):
            return onlineMemberIds.contains(member.memberId) ? "Online" : "Offline"
        case .agent(let agent):
            return agent.statusLabel
        }
    }

    private var statusForeground: Color {
        switch actor {
        case .member(let member):
            return onlineMemberIds.contains(member.memberId) ? .green : .secondary
        case .agent(let agent):
            switch agent.status {
            case 2: return .green
            case 3: return .yellow
            case 4, 5: return .red
            default: return .secondary
            }
        }
    }
}

private func actorDisplayName(for agent: Agent) -> String {
    if !agent.sessionTitle.isEmpty { return agent.sessionTitle }
    return agent.agentId
}
