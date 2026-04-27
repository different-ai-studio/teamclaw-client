import SwiftUI
import AMUXCore

struct ArchivedTasksView: View {
    @Environment(\.dismiss) private var dismiss

    @Bindable var taskStore: TaskStore

    var body: some View {
        NavigationStack {
            Group {
                if taskStore.archivedTasks.isEmpty {
                    ContentUnavailableView(
                        "Nothing Archived",
                        systemImage: "archivebox",
                        description: Text("Archived ideas will show up here.")
                    )
                } else {
                    List {
                        ForEach(taskStore.archivedTasks) { item in
                            TaskRow(item: item)
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button {
                                        Task { await taskStore.setArchived(taskID: item.id, archived: false) }
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
}
