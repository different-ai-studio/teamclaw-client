import SwiftUI
import SwiftData
import AMUXCore

/// Mac-native task detail pane. Mirrors iOS TaskDetailView functionality
/// (status change, description, linked session, creator info) in a
/// mouse-first layout with an Edit button that opens TaskEditorWindow.
struct TaskDetailView: View {
    let item: SessionTask
    let teamclawService: TeamclawService
    let mqtt: MQTTService?
    let deviceId: String
    let peerId: String
    @Binding var selectedSessionId: String?

    @Environment(\.modelContext) private var modelContext
    @Environment(\.openWindow) private var openWindow
    @Query private var members: [Member]
    @Query private var agents: [Agent]
    @Query private var sessions: [Session]

    static func statusDisplay(for raw: String) -> String {
        switch raw {
        case "open": return "Open"
        case "in_progress": return "In Progress"
        case "done": return "Done"
        case "": return "Unknown"
        default: return raw
        }
    }

    private var creatorLabel: String {
        guard !item.createdBy.isEmpty else { return "—" }
        return members.first(where: { $0.memberId == item.createdBy })?.displayName ?? "Unknown"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                Divider()
                statusSection
                if !item.taskDescription.isEmpty { descriptionSection }
                if !item.sessionId.isEmpty { linkedSessionSection }
                metadataSection
                Spacer(minLength: 40)
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    openWindow(
                        id: "amux.taskEditor",
                        value: TaskEditorInput(taskId: item.taskId)
                    )
                } label: {
                    Label("Edit", systemImage: "pencil")
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "checkmark.circle")
                .foregroundStyle(.secondary)
            Text(item.displayTitle)
                .font(.title2.weight(.semibold))
                .textSelection(.enabled)
            Spacer()
        }
    }

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Status").font(.headline)
            HStack(spacing: 8) {
                statusPill("Open", value: "open")
                statusPill("In Progress", value: "in_progress")
                statusPill("Done", value: "done")
            }
        }
    }

    private var descriptionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Description").font(.headline)
            Text(item.taskDescription)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var metadataSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Info").font(.headline)
            LabeledContent("Created by", value: creatorLabel)
            LabeledContent("Created", value: item.createdAt.formatted(date: .abbreviated, time: .shortened))
            LabeledContent("Status", value: Self.statusDisplay(for: item.status))
        }
    }

    @ViewBuilder
    private var linkedSessionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Related Session").font(.headline)
            if let agent = agents.first(where: { $0.agentId == item.sessionId }) {
                Button {
                    selectedSessionId = agent.agentId
                } label: {
                    HStack {
                        Text(agent.sessionTitle.isEmpty ? agent.agentId : agent.sessionTitle)
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            } else if let session = sessions.first(where: { $0.sessionId == item.sessionId }) {
                Button {
                    selectedSessionId = session.sessionId
                } label: {
                    HStack {
                        Text(session.title.isEmpty ? session.sessionId : session.title)
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            } else {
                Text("Session not loaded yet").foregroundStyle(.secondary)
            }
        }
    }

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
        item.status = newValue
        try? modelContext.save()
        let id = item.taskId
        let sid = item.sessionId
        Task { await teamclawService.updateTaskStatus(taskId: id, sessionId: sid, status: newValue) }
    }
}
