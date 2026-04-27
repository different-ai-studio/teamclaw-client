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

    @Query(filter: #Predicate<SessionTask> { !$0.archived })
    private var allTasks: [SessionTask]

    @Query(filter: #Predicate<CachedActor> { $0.actorType == "member" },
           sort: \CachedActor.displayName)
    private var allMembers: [CachedActor]

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

    private var runtimeMatches: [Runtime] {
        viewModel.runtimes.filter {
            SearchMatcher.matchesAny(
                fields: [$0.sessionTitle, $0.currentPrompt, $0.worktree],
                query: query
            )
        }
    }

    private var taskMatches: [SessionTask] {
        allTasks.filter {
            SearchMatcher.matchesAny(
                fields: [$0.title, $0.taskDescription],
                query: query
            )
        }
    }

    private var memberMatches: [CachedActor] {
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
                        description: Text("Search sessions, ideas, and members."))
                } else {
                    if !runtimeMatches.isEmpty {
                        Section("Sessions") {
                            ForEach(runtimeMatches, id: \.runtimeId) { runtime in
                                Button {
                                    rootSelection = .sessions
                                    sessionsPath.append(runtime.runtimeId)
                                } label: {
                                    AgentRowView(
                                        runtime: runtime,
                                        workspaceName: workspaceName(for: runtime)
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    if !taskMatches.isEmpty {
                        Section("Ideas") {
                            ForEach(taskMatches, id: \.taskId) { item in
                                TaskRow(item: item)
                            }
                        }
                    }

                    if !memberMatches.isEmpty {
                        Section("Members") {
                            ForEach(memberMatches, id: \.actorId) { member in
                                HStack {
                                    Text(member.displayName)
                                        .font(.body)
                                    Spacer()
                                    Text(member.roleLabel)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }

                    if runtimeMatches.isEmpty && taskMatches.isEmpty && memberMatches.isEmpty {
                        ContentUnavailableView.search(text: query)
                    }
                }
            }
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.large)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always))
        }
    }

    private func workspaceName(for runtime: Runtime) -> String {
        viewModel.workspaces.first(where: { $0.workspaceId == runtime.workspaceId })?.displayName ?? ""
    }
}
