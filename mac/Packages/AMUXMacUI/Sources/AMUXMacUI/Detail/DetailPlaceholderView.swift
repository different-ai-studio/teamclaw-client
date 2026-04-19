import SwiftUI
import SwiftData
import AMUXCore

struct DetailPlaceholderView: View {
    let teamclawService: TeamclawService
    let actorId: String
    @Binding var selectedSessionId: String?
    let selectedTaskId: String?
    let mqtt: MQTTService?
    let deviceId: String
    let peerId: String

    @Query private var sessions: [CollabSession]
    @Query private var tasks: [WorkItem]

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if let session = selectedSession {
                    SessionDetailView(
                        session: session,
                        teamclawService: teamclawService,
                        actorId: actorId,
                        mqtt: mqtt,
                        deviceId: deviceId,
                        peerId: peerId
                    )
                } else if let task = selectedTask {
                    TaskDetailView(
                        item: task,
                        teamclawService: teamclawService,
                        mqtt: mqtt,
                        deviceId: deviceId,
                        peerId: peerId,
                        selectedSessionId: $selectedSessionId
                    )
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

}

