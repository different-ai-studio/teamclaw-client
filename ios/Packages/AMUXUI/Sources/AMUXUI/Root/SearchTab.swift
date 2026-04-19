import SwiftUI
import SwiftData
import AMUXCore

public struct SearchTab: View {
    let mqtt: MQTTService
    let pairing: PairingManager
    let teamclawService: TeamclawService?
    @Bindable var viewModel: SessionListViewModel
    @Binding var rootSelection: AppTab
    @Binding var sessionsPath: [String]

    @Environment(\.modelContext) private var modelContext
    @State private var query: String = ""

    @Query(filter: #Predicate<WorkItem> { !$0.archived })
    private var allTasks: [WorkItem]

    @Query private var allMembers: [Member]

    public init(mqtt: MQTTService,
                pairing: PairingManager,
                teamclawService: TeamclawService?,
                viewModel: SessionListViewModel,
                rootSelection: Binding<AppTab>,
                sessionsPath: Binding<[String]>) {
        self.mqtt = mqtt
        self.pairing = pairing
        self.teamclawService = teamclawService
        self.viewModel = viewModel
        self._rootSelection = rootSelection
        self._sessionsPath = sessionsPath
    }

    private var agentMatches: [Agent] {
        viewModel.agents.filter {
            SearchMatcher.matchesAny(
                fields: [$0.sessionTitle, $0.currentPrompt, $0.worktree],
                query: query
            )
        }
    }

    private var taskMatches: [WorkItem] {
        allTasks.filter {
            SearchMatcher.matchesAny(
                fields: [$0.title, $0.itemDescription],
                query: query
            )
        }
    }

    private var memberMatches: [Member] {
        allMembers.filter {
            SearchMatcher.matches(haystack: $0.displayName, query: query)
        }
    }

    public var body: some View {
        NavigationStack {
            List {
                if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ContentUnavailableView("Search",
                        systemImage: "magnifyingglass",
                        description: Text("Search sessions, tasks, and members."))
                } else {
                    if !agentMatches.isEmpty {
                        Section("Sessions") {
                            ForEach(agentMatches, id: \.agentId) { agent in
                                Button {
                                    rootSelection = .sessions
                                    sessionsPath.append(agent.agentId)
                                } label: {
                                    AgentRowView(
                                        agent: agent,
                                        workspaceName: workspaceName(for: agent)
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    if !taskMatches.isEmpty {
                        Section("Tasks") {
                            ForEach(taskMatches, id: \.workItemId) { item in
                                WorkItemRow(item: item)
                            }
                        }
                    }

                    if !memberMatches.isEmpty {
                        Section("Members") {
                            ForEach(memberMatches, id: \.memberId) { member in
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(member.displayName)
                                            .font(.body)
                                        if let dept = member.department, !dept.isEmpty {
                                            Text(dept)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    Text(member.roleLabel)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }

                    if agentMatches.isEmpty && taskMatches.isEmpty && memberMatches.isEmpty {
                        ContentUnavailableView.search(text: query)
                    }
                }
            }
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.large)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always))
        }
    }

    private func workspaceName(for agent: Agent) -> String {
        viewModel.workspaces.first(where: { $0.workspaceId == agent.workspaceId })?.displayName ?? ""
    }
}
