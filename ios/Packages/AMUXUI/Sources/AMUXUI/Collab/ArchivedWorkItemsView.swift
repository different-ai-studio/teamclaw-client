import SwiftUI
import SwiftData
import AMUXCore

struct ArchivedTasksView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let teamclawService: TeamclawService?

    @Query(filter: #Predicate<SessionTask> { $0.archived },
           sort: \SessionTask.createdAt, order: .reverse)
    private var archivedItems: [SessionTask]

    var body: some View {
        NavigationStack {
            Group {
                if archivedItems.isEmpty {
                    ContentUnavailableView(
                        "Nothing Archived",
                        systemImage: "archivebox",
                        description: Text("Archived tasks will show up here.")
                    )
                } else {
                    List {
                        ForEach(archivedItems, id: \.taskId) { item in
                            TaskRow(item: item)
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button {
                                        unarchiveTapped(item)
                                    } label: {
                                        Label("Unarchive", systemImage: "tray.and.arrow.up")
                                    }
                                    .tint(.blue)
                                }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Archived")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").font(.title3)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func unarchiveTapped(_ item: SessionTask) {
        item.archived = false
        try? modelContext.save()
        let id = item.taskId
        let sessionId = item.sessionId
        Task { await teamclawService?.archiveTask(taskId: id, sessionId: sessionId, archived: false) }
    }
}
