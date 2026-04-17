import SwiftUI
import SwiftData
import AMUXCore

struct TaskListColumn: View {
    @Binding var selectedTaskId: String?

    @Query private var allTasks: [WorkItem]
    @Query private var allSessions: [CollabSession]

    var body: some View {
        let sortedTasks = allTasks.sorted(by: TaskListColumn.compare)

        if sortedTasks.isEmpty {
            ContentUnavailableView("No tasks yet", systemImage: "checkmark.circle")
        } else {
            List(sortedTasks, id: \.workItemId, selection: $selectedTaskId) { task in
                TaskRow(
                    workItem: task,
                    sessionTitle: sessionTitle(for: task.sessionId)
                )
                .tag(task.workItemId)
            }
            .listStyle(.inset)
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
