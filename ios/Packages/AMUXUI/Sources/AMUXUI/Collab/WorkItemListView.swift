import SwiftUI
import SwiftData
import AMUXCore

/// Pushable/embeddable task list body. Parent owns NavigationStack
/// and provides the "+" toolbar action.
public struct TaskListView: View {
    @Environment(\.modelContext) private var modelContext

    let pairing: PairingManager
    let connectionMonitor: ConnectionMonitor
    let teamclawService: TeamclawService?

    // SwiftData-driven list; any mutation from syncTaskEvent refreshes
    // the UI without manual reloads.
    @Query(filter: #Predicate<SessionTask> { !$0.archived },
           sort: \SessionTask.createdAt, order: .reverse)
    private var tasks: [SessionTask]

    // Count of archived items for the "Archived (N)" footer row.
    @Query(filter: #Predicate<SessionTask> { $0.archived })
    private var archivedItems: [SessionTask]

    @Query private var members: [Member]

    private var memberNameById: [String: String] {
        Dictionary(uniqueKeysWithValues: members.map { ($0.memberId, $0.displayName) })
    }

    @Binding var showCreate: Bool
    @State private var showArchived = false

    public init(pairing: PairingManager,
                connectionMonitor: ConnectionMonitor,
                teamclawService: TeamclawService? = nil,
                showCreate: Binding<Bool>) {
        self.pairing = pairing
        self.connectionMonitor = connectionMonitor
        self.teamclawService = teamclawService
        self._showCreate = showCreate
    }

    public var body: some View {
        VStack(spacing: 0) {
            if tasks.isEmpty {
                ContentUnavailableView("No Tasks", systemImage: "checklist",
                    description: Text("Tap + to create a task"))
            } else {
                List {
                    ForEach(tasks, id: \.taskId) { item in
                        NavigationLink(value: "task:\(item.taskId)") {
                            TaskRow(item: item,
                                    creatorName: creatorLabel(for: item))
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button {
                                archiveTapped(item)
                            } label: {
                                Label("Archive", systemImage: "archivebox.fill")
                            }
                            .tint(.gray)
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Tasks")
        .navigationBarTitleDisplayMode(.large)
        .safeAreaInset(edge: .bottom) {
            if !archivedItems.isEmpty {
                Button {
                    showArchived = true
                } label: {
                    HStack {
                        Image(systemName: "archivebox")
                        Text("Archived (\(archivedItems.count))")
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
            CreateTaskSheet(teamclawService: teamclawService) { }
        }
        .sheet(isPresented: $showArchived) {
            ArchivedTasksView(teamclawService: teamclawService)
        }
    }

    private func creatorLabel(for item: SessionTask) -> String? {
        guard !item.createdBy.isEmpty else { return nil }
        // Show the member's display name, or nothing — never the raw id.
        return memberNameById[item.createdBy]
    }

    private func archiveTapped(_ item: SessionTask) {
        // Optimistic flip — @Query animates the row out immediately.
        item.archived = true
        try? modelContext.save()
        let id = item.taskId
        let sessionId = item.sessionId
        Task { await teamclawService?.archiveTask(taskId: id, sessionId: sessionId, archived: true) }
    }
}
