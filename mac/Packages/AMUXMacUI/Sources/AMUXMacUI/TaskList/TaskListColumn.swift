import SwiftUI
import SwiftData
import AMUXCore

struct TaskListColumn: View {
    @Binding var selectedTaskId: String?
    let teamclawService: TeamclawService?

    @Environment(\.openWindow) private var openWindow

    @Query(filter: #Predicate<WorkItem> { !$0.archived })
    private var allTasks: [WorkItem]
    @Query private var allSessions: [CollabSession]

    var body: some View {
        let sortedTasks = allTasks.sorted(by: TaskListColumn.compare)

        Group {
            if sortedTasks.isEmpty {
                ContentUnavailableView("No tasks yet", systemImage: "checkmark.circle")
            } else {
                List(sortedTasks, id: \.workItemId, selection: $selectedTaskId) { task in
                    TaskRow(
                        workItem: task,
                        sessionTitle: sessionTitle(for: task.sessionId),
                        teamclawService: teamclawService
                    )
                    .tag(task.workItemId)
                }
                .listStyle(.inset)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    openWindow(id: "amux.taskEditor", value: TaskEditorInput())
                } label: {
                    Label("New Task", systemImage: "plus")
                }
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
