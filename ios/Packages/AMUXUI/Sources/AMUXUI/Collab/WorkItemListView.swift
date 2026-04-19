import SwiftUI
import SwiftData
import AMUXCore

/// Pushable/embeddable work item list body. Parent owns NavigationStack
/// and provides the "+" toolbar action.
public struct WorkItemListView: View {
    @Environment(\.modelContext) private var modelContext

    let pairing: PairingManager
    let connectionMonitor: ConnectionMonitor
    let teamclawService: TeamclawService?

    // SwiftData-driven list; any mutation from syncWorkItemEvent refreshes
    // the UI without manual reloads.
    @Query(filter: #Predicate<WorkItem> { !$0.archived },
           sort: \WorkItem.createdAt, order: .reverse)
    private var workItems: [WorkItem]

    // Count of archived items for the "Archived (N)" footer row.
    @Query(filter: #Predicate<WorkItem> { $0.archived })
    private var archivedItems: [WorkItem]

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
            if workItems.isEmpty {
                ContentUnavailableView("No Tasks", systemImage: "checklist",
                    description: Text("Tap + to create a task"))
            } else {
                List {
                    ForEach(workItems, id: \.workItemId) { item in
                        NavigationLink(value: "task:\(item.workItemId)") {
                            WorkItemRow(item: item)
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
            CreateWorkItemSheet(teamclawService: teamclawService) { }
        }
        .sheet(isPresented: $showArchived) {
            ArchivedWorkItemsView(teamclawService: teamclawService)
        }
    }

    private func archiveTapped(_ item: WorkItem) {
        // Optimistic flip — @Query animates the row out immediately.
        item.archived = true
        try? modelContext.save()
        let id = item.workItemId
        let sessionId = item.sessionId
        Task { await teamclawService?.archiveWorkItem(workItemId: id, sessionId: sessionId, archived: true) }
    }
}
