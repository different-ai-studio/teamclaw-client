import SwiftUI
import SwiftData
import AMUXCore

public struct TaskListView: View {
    @Bindable var taskStore: TaskStore

    @Query(filter: #Predicate<CachedActor> { $0.actorType == "member" },
           sort: \CachedActor.displayName)
    private var members: [CachedActor]

    private var memberNameById: [String: String] {
        Dictionary(uniqueKeysWithValues: members.map { ($0.actorId, $0.displayName) })
    }

    @Binding var showCreate: Bool
    @State private var showArchived = false

    public init(taskStore: TaskStore, showCreate: Binding<Bool>) {
        self.taskStore = taskStore
        self._showCreate = showCreate
    }

    public var body: some View {
        VStack(spacing: 0) {
            if let errorMessage = taskStore.errorMessage, taskStore.tasks.isEmpty, !taskStore.isLoading {
                ContentUnavailableView(
                    "Couldn’t Load Tasks",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage)
                )
            } else if taskStore.isLoading && taskStore.tasks.isEmpty {
                ProgressView("Loading tasks…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if taskStore.tasks.isEmpty {
                ContentUnavailableView(
                    "No Tasks",
                    systemImage: "checklist",
                    description: Text("Tap + to create a task")
                )
            } else {
                List {
                    ForEach(taskStore.tasks) { item in
                        NavigationLink(value: item) {
                            TaskRow(item: item, creatorName: creatorLabel(for: item))
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button {
                                Task { await taskStore.setArchived(taskID: item.id, archived: true) }
                            } label: {
                                Label("Archive", systemImage: "archivebox.fill")
                            }
                            .tint(.gray)
                        }
                    }
                }
                .listStyle(.plain)
                .refreshable {
                    await taskStore.reload()
                }
            }
        }
        .navigationTitle("Tasks")
        .navigationBarTitleDisplayMode(.large)
        .safeAreaInset(edge: .bottom) {
            if !taskStore.archivedTasks.isEmpty {
                Button {
                    showArchived = true
                } label: {
                    HStack {
                        Image(systemName: "archivebox")
                        Text("Archived (\(taskStore.archivedTasks.count))")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .font(.body)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .padding(.horizontal, 16)
                }
                .buttonStyle(.plain)
            }
        }
        .sheet(isPresented: $showCreate) {
            CreateTaskSheet(taskStore: taskStore) { }
        }
        .sheet(isPresented: $showArchived) {
            ArchivedTasksView(taskStore: taskStore)
        }
    }

    private func creatorLabel(for item: TaskRecord) -> String? {
        guard !item.createdByActorID.isEmpty else { return nil }
        return memberNameById[item.createdByActorID]
    }
}
