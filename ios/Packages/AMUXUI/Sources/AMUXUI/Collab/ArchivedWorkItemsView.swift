import SwiftUI
import SwiftData
import AMUXCore

struct ArchivedWorkItemsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let teamclawService: TeamclawService?

    @Query(filter: #Predicate<WorkItem> { $0.archived },
           sort: \WorkItem.createdAt, order: .reverse)
    private var archivedItems: [WorkItem]

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
                        ForEach(archivedItems, id: \.workItemId) { item in
                            WorkItemRow(item: item)
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

    private func unarchiveTapped(_ item: WorkItem) {
        item.archived = false
        try? modelContext.save()
        let id = item.workItemId
        let sessionId = item.sessionId
        Task { await teamclawService?.archiveWorkItem(workItemId: id, sessionId: sessionId, archived: false) }
    }
}
