import SwiftUI
import SwiftData
import AMUXCore

struct TaskListColumn: View {
    @Binding var selectedTaskId: String?
    let teamclawService: TeamclawService?
    let archivedVisible: Bool

    @Environment(\.openWindow) private var openWindow

    @Query(filter: #Predicate<WorkItem> { !$0.archived })
    private var allTasks: [WorkItem]
    @Query(filter: #Predicate<WorkItem> { $0.archived }, sort: \WorkItem.createdAt, order: .reverse)
    private var archivedTasks: [WorkItem]
    @Query private var allSessions: [CollabSession]

    @State private var archivedExpanded: Bool = false

    var body: some View {
        let sortedTasks = allTasks.sorted(by: TaskListColumn.compare)

        VStack(spacing: 0) {
            if sortedTasks.isEmpty && (!archivedVisible || archivedTasks.isEmpty) {
                ContentUnavailableView("No tasks yet", systemImage: "checkmark.circle")
            } else {
                List(selection: $selectedTaskId) {
                    ForEach(sortedTasks, id: \.workItemId) { task in
                        TaskRow(
                            workItem: task,
                            sessionTitle: sessionTitle(for: task.sessionId),
                            teamclawService: teamclawService
                        )
                        .tag(task.workItemId)
                    }
                    if archivedVisible && !archivedTasks.isEmpty {
                        Section {
                            DisclosureGroup("Archived (\(archivedTasks.count))", isExpanded: $archivedExpanded) {
                                ForEach(archivedTasks, id: \.workItemId) { task in
                                    TaskRow(
                                        workItem: task,
                                        sessionTitle: sessionTitle(for: task.sessionId),
                                        teamclawService: teamclawService
                                    )
                                    .tag(task.workItemId)
                                    .opacity(0.55)
                                    .contextMenu {
                                        Button("Unarchive") {
                                            let id = task.workItemId
                                            let sid = task.sessionId
                                            Task { await teamclawService?.archiveWorkItem(workItemId: id, sessionId: sid, archived: false) }
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
        .navigationTitle("Tasks")
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

    /// Sort: open first, then in_progress, then done. Within each, newest first.
    static func compare(lhs: WorkItem, rhs: WorkItem) -> Bool {
        let order: [String: Int] = ["open": 0, "in_progress": 1, "done": 2]
        let lhsRank = order[lhs.status, default: 3]
        let rhsRank = order[rhs.status, default: 3]
        if lhsRank != rhsRank { return lhsRank < rhsRank }
        return lhs.createdAt > rhs.createdAt
    }
}
