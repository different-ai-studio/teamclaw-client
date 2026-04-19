import SwiftUI
import SwiftData
import AMUXCore

/// Pushable task detail. Rendered via TasksTab's navigationDestination.
/// Takes the WorkItem directly (SwiftData @Model observability re-renders
/// this view when the daemon broadcast reconciles state).
public struct TaskDetailView: View {
    let item: WorkItem
    let sessionViewModel: SessionListViewModel
    let teamclawService: TeamclawService?
    let mqtt: MQTTService
    let deviceId: String
    let peerId: String
    @Binding var navigationPath: [String]

    @Environment(\.modelContext) private var modelContext
    @Query private var members: [Member]
    @State private var showNewSession = false

    private var creatorLabel: String {
        guard !item.createdBy.isEmpty else { return "—" }
        if let m = members.first(where: { $0.memberId == item.createdBy }) {
            return m.displayName
        }
        return "Unknown"
    }

    public init(item: WorkItem,
                sessionViewModel: SessionListViewModel,
                teamclawService: TeamclawService?,
                mqtt: MQTTService,
                deviceId: String,
                peerId: String,
                navigationPath: Binding<[String]>) {
        self.item = item
        self.sessionViewModel = sessionViewModel
        self.teamclawService = teamclawService
        self.mqtt = mqtt
        self.deviceId = deviceId
        self.peerId = peerId
        self._navigationPath = navigationPath
    }

    public var body: some View {
        List {
            Section {
                Text(item.displayTitle)
                    .font(.title2.weight(.semibold))
                    .textSelection(.enabled)
            }

            Section("Status") {
                HStack(spacing: 8) {
                    statusPill("Open", value: "open")
                    statusPill("In Progress", value: "in_progress")
                    statusPill("Done", value: "done")
                }
                .padding(.vertical, 4)
            }

            if !item.itemDescription.isEmpty {
                Section("Description") {
                    Text(item.itemDescription)
                        .font(.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if !item.sessionId.isEmpty {
                Section("Related Session") {
                    relatedSessionRow
                }
            }

            Section("Info") {
                LabeledContent("Created by", value: creatorLabel)
                LabeledContent("Created", value: item.createdAt.formatted(date: .abbreviated, time: .shortened))
            }
        }
        .navigationTitle("Task")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showNewSession = true
                } label: {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.title3)
                        .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Create session")
            }
        }
        .sheet(isPresented: $showNewSession) {
            NewSessionSheet(
                mqtt: mqtt,
                deviceId: deviceId,
                peerId: peerId,
                viewModel: sessionViewModel,
                preselectedWorkItemId: item.workItemId,
                onSessionCreated: { sessionKey in
                    showNewSession = false
                    navigationPath.append(sessionKey)
                }
            )
        }
    }

    // MARK: - Status pill

    private func statusPill(_ label: String, value: String) -> some View {
        let selected = item.status == value
        return Button {
            setStatus(value)
        } label: {
            Text(label)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .foregroundStyle(selected ? Color.white : Color.primary)
                .background(selected ? Color.accentColor : Color.clear)
                .clipShape(Capsule())
                .overlay(
                    Capsule().strokeBorder(selected ? Color.clear : Color.secondary.opacity(0.4), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    private func setStatus(_ newValue: String) {
        guard item.status != newValue else { return }
        // Optimistic — SwiftData @Model re-renders this view immediately.
        item.status = newValue
        try? modelContext.save()
        let id = item.workItemId
        let sessionId = item.sessionId
        Task { await teamclawService?.updateWorkItemStatus(workItemId: id, sessionId: sessionId, status: newValue) }
    }

    // MARK: - Related session row

    @ViewBuilder
    private var relatedSessionRow: some View {
        if let agent = sessionViewModel.agents.first(where: { $0.agentId == item.sessionId }) {
            Button {
                navigationPath.append(agent.agentId)
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(agent.sessionTitle.isEmpty ? agent.agentId : agent.sessionTitle)
                            .font(.body)
                            .foregroundStyle(.primary)
                        Text("Tap to open")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
        } else if let collab = sessionViewModel.collabSessions.first(where: { $0.sessionId == item.sessionId }) {
            Button {
                navigationPath.append("collab:\(collab.sessionId)")
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(collab.title.isEmpty ? collab.sessionId : collab.title)
                            .font(.body)
                            .foregroundStyle(.primary)
                        Text("Tap to open")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
        } else {
            HStack {
                Text("Session not loaded yet")
                    .font(.body)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
    }
}
