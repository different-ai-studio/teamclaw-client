import SwiftUI
import SwiftData
import AMUXCore

struct DetailPlaceholderView: View {
    let pairing: PairingManager
    let monitor: ConnectionMonitor?
    let teamclawService: TeamclawService
    let actorId: String
    let selectedSessionId: String?
    let selectedTaskId: String?

    @Query private var sessions: [CollabSession]
    @Query private var tasks: [WorkItem]

    var body: some View {
        VStack(spacing: 0) {
            DaemonStatusBar(pairing: pairing, monitor: monitor)
            Divider()

            Group {
                if let session = selectedSession {
                    SessionDetailView(session: session, teamclawService: teamclawService, actorId: actorId)
                } else if let task = selectedTask {
                    taskPreview(task)
                } else {
                    ContentUnavailableView(
                        "Select a session or task",
                        systemImage: "sidebar.right",
                        description: Text("Detail view, message stream, and composer arrive in the next plan.")
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var selectedSession: CollabSession? {
        guard let id = selectedSessionId else { return nil }
        return sessions.first(where: { $0.sessionId == id })
    }

    private var selectedTask: WorkItem? {
        guard let id = selectedTaskId else { return nil }
        return tasks.first(where: { $0.workItemId == id })
    }

    @ViewBuilder
    private func taskPreview(_ task: WorkItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(task.title.isEmpty ? "(untitled task)" : task.title, systemImage: "checkmark.circle")
                .font(.title2.weight(.semibold))
            Text(task.statusLabel)
                .foregroundStyle(.secondary)
            if !task.itemDescription.isEmpty {
                Text(task.itemDescription)
                    .padding(.top, 4)
            }
            Text("Linked session view coming in Plan 4.")
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(24)
    }
}

private struct DaemonStatusBar: View {
    let pairing: PairingManager
    let monitor: ConnectionMonitor?

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(monitor?.daemonOnline == true ? Color.green : Color.red)
                .frame(width: 8, height: 8)
            Text(monitor?.daemonOnline == true ? "Daemon online" : "Daemon offline")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Text("\(pairing.brokerHost):\(pairing.brokerPort) · \(pairing.deviceId)")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}
