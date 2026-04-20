import SwiftUI
import SwiftData
import AMUXCore

struct TaskListColumn: View {
    @Binding var selectedTaskId: String?
    let teamclawService: TeamclawService?
    let archivedVisible: Bool
    let workspaceFilter: String?
    let workspaceName: String?

    @Environment(\.openWindow) private var openWindow

    @Query(filter: #Predicate<SessionTask> { !$0.archived })
    private var allTasks: [SessionTask]
    @Query(filter: #Predicate<SessionTask> { $0.archived }, sort: \SessionTask.createdAt, order: .reverse)
    private var archivedTasks: [SessionTask]
    @Query private var allSessions: [Session]
    @Query private var allAgents: [Agent]

    @State private var archivedExpanded: Bool = false

    var body: some View {
        let sortedTasks = filteredTasks(allTasks).sorted(by: TaskListColumn.compare)
        let visibleArchivedTasks = filteredTasks(archivedTasks)

        VStack(spacing: 0) {
            if sortedTasks.isEmpty && (!archivedVisible || visibleArchivedTasks.isEmpty) {
                ContentUnavailableView("No tasks yet", systemImage: "checkmark.circle")
            } else {
                List(selection: $selectedTaskId) {
                    ForEach(sortedTasks, id: \.taskId) { task in
                        TaskRow(
                            task: task,
                            sessionTitle: sessionTitle(for: task.sessionId),
                            teamclawService: teamclawService
                        )
                        .tag(task.taskId)
                    }
                    if archivedVisible && !visibleArchivedTasks.isEmpty {
                        Section {
                            DisclosureGroup("Archived (\(visibleArchivedTasks.count))", isExpanded: $archivedExpanded) {
                                ForEach(visibleArchivedTasks, id: \.taskId) { task in
                                    TaskRow(
                                        task: task,
                                        sessionTitle: sessionTitle(for: task.sessionId),
                                        teamclawService: teamclawService
                                    )
                                    .tag(task.taskId)
                                    .opacity(0.55)
                                    .contextMenu {
                                        Button("Unarchive") {
                                            let id = task.taskId
                                            let sid = task.sessionId
                                            Task { await teamclawService?.archiveTask(taskId: id, sessionId: sid, archived: false) }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle(workspaceName ?? "Tasks")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    openWindow(id: "amux.taskEditor", value: TaskEditorInput())
                } label: {
                    Label("New Task", systemImage: "plus")
                }
                .keyboardShortcut("n", modifiers: .command)
                .help("New Task (⌘N)")
            }
        }
    }

    private func sessionTitle(for id: String) -> String? {
        allSessions.first(where: { $0.sessionId == id })?.title
    }

    private func filteredTasks(_ tasks: [SessionTask]) -> [SessionTask] {
        guard let workspaceFilter else { return tasks }
        let sessionLookup = Dictionary(uniqueKeysWithValues: allSessions.map { ($0.sessionId, $0) })
        let agentLookup = Dictionary(uniqueKeysWithValues: allAgents.map { ($0.agentId, $0) })
        return tasks.filter { task in
            guard let session = sessionLookup[task.sessionId],
                  let agentId = session.primaryAgentId,
                  let agent = agentLookup[agentId] else {
                return false
            }
            return agent.workspaceId == workspaceFilter
        }
    }

    /// Sort: open first, then in_progress, then done. Within each, newest first.
    static func compare(lhs: SessionTask, rhs: SessionTask) -> Bool {
        let order: [String: Int] = ["open": 0, "in_progress": 1, "done": 2]
        let lhsRank = order[lhs.status, default: 3]
        let rhsRank = order[rhs.status, default: 3]
        if lhsRank != rhsRank { return lhsRank < rhsRank }
        return lhs.createdAt > rhs.createdAt
    }
}
