import SwiftUI
import SwiftData
import AMUXCore

public struct WorkItemSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let pairing: PairingManager
    let connectionMonitor: ConnectionMonitor

    @State private var workItems: [WorkItem] = []
    @State private var showSettings = false

    public init(pairing: PairingManager, connectionMonitor: ConnectionMonitor) {
        self.pairing = pairing
        self.connectionMonitor = connectionMonitor
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if workItems.isEmpty {
                    ContentUnavailableView("No Work Items", systemImage: "checklist",
                        description: Text("Work items from collab sessions will appear here"))
                } else {
                    List {
                        ForEach(workItems, id: \.workItemId) { item in
                            WorkItemRow(item: item)
                        }
                    }
                    .listStyle(.plain)
                }

                Spacer()

                // Settings button at bottom
                Button { showSettings = true } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "gearshape")
                        Text("Settings")
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
            }
            .navigationTitle("Work Items")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").font(.title3)
                    }
                    .buttonStyle(.plain)
                }
            }
            .task { loadWorkItems() }
            .sheet(isPresented: $showSettings) {
                SettingsView(pairing: pairing, connectionMonitor: connectionMonitor)
            }
        }
    }

    private func loadWorkItems() {
        let descriptor = FetchDescriptor<WorkItem>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        workItems = (try? modelContext.fetch(descriptor)) ?? []
    }
}

struct WorkItemRow: View {
    let item: WorkItem

    var body: some View {
        HStack(spacing: 10) {
            // Status indicator
            Circle()
                .fill(item.isDone ? .green : item.isInProgress ? Color.orange : Color.blue)
                .frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.body)
                    .fontWeight(.medium)
                    .lineLimit(1)

                HStack(spacing: 8) {
                    Text(item.statusLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if !item.itemDescription.isEmpty {
                        Text(item.itemDescription)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }

            Spacer()

            Text(item.createdAt, style: .relative)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
