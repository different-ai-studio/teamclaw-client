import SwiftUI
import SwiftData
import AMUXCore

struct DetailPlaceholderView: View {
    let teamclawService: TeamclawService
    let actorId: String
    @Binding var selectedSessionId: String?
    let selectedIdeaId: String?
    let mqtt: MQTTService?
    let deviceId: String
    let peerId: String

    @Query private var sessions: [Session]
    @Query private var agents: [Agent]
    @Query private var ideas: [SessionIdea]

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
                } else if let idea = selectedIdea {
                    IdeaDetailView(
                        item: idea,
                        teamclawService: teamclawService,
                        mqtt: mqtt,
                        deviceId: deviceId,
                        peerId: peerId,
                        selectedSessionId: $selectedSessionId
                    )
                } else {
                    ContentUnavailableView(
                        "Select a session or idea",
                        systemImage: "sidebar.right",
                        description: Text("Detail view, message stream, and composer arrive in the next plan.")
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var selectedSession: Session? {
        guard let rawId = selectedSessionId else { return nil }
        let id = normalizedSelectionId(rawId)
        if let real = sessions.first(where: { $0.sessionId == id }) {
            return real
        }
        // Fall back to a display-only wrapper when the selection refers to a
        // solo agent (one that never acquired a shared session). Not persisted
        // — SessionDetailView only reads fields and routes through
        // AgentDetailViewModel via `primaryAgentId`. This lets the detail view
        // render the agent's event feed without requiring a real teamclaw
        // session on the daemon. See 2026-04-20 Mac alignment with iOS.
        if let agent = agents.first(where: { $0.agentId == id }) {
            let stub = Session(
                sessionId: agent.agentId,
                mode: "solo",
                title: agent.sessionTitle.isEmpty ? agent.currentPrompt : agent.sessionTitle,
                createdAt: agent.startedAt,
                lastMessageAt: agent.lastEventTime
            )
            stub.primaryAgentId = agent.agentId
            return stub
        }
        return nil
    }

    private func normalizedSelectionId(_ rawId: String) -> String {
        if rawId.hasPrefix("collab:") {
            return String(rawId.dropFirst("collab:".count))
        }
        if rawId.hasPrefix("agent:") {
            return String(rawId.dropFirst("agent:".count))
        }
        return rawId
    }

    private var selectedIdea: SessionIdea? {
        guard let id = selectedIdeaId else { return nil }
        return ideas.first(where: { $0.ideaId == id })
    }

}
