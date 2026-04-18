import SwiftUI
import SwiftData
import AMUXCore

struct SessionDetailView: View {
    let session: CollabSession
    let teamclawService: TeamclawService
    let actorId: String

    @Environment(\.modelContext) private var modelContext

    @Query private var allMessages: [SessionMessage]
    @Query private var allAgents: [Agent]

    private var primaryAgent: Agent? {
        guard let id = session.primaryAgentId else { return nil }
        return allAgents.first(where: { $0.agentId == id })
    }

    var body: some View {
        let messages = allMessages
            .filter { $0.sessionId == session.sessionId }
            .sorted { $0.createdAt < $1.createdAt }

        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    DetailHeaderView(session: session, participantSummary: participantSummary(messages))

                    if messages.isEmpty {
                        Text("No messages yet.")
                            .foregroundStyle(.tertiary)
                            .padding(22)
                    } else {
                        ForEach(messages, id: \.messageId) { message in
                            rowView(for: message)
                        }
                        .padding(.bottom, 22)
                    }
                }
            }

            ComposerView(
                teamclawService: teamclawService,
                sessionId: session.sessionId,
                actorId: actorId,
                agent: primaryAgent
            )
        }
        .task(id: session.sessionId) {
            teamclawService.subscribeToSession(session.sessionId)
        }
    }

    private func participantSummary(_ messages: [SessionMessage]) -> String {
        let senders = Set(messages.map(\.senderActorId).filter { !$0.isEmpty })
        if senders.isEmpty { return "(no participants yet)" }
        let sorted = senders.sorted()
        let head = sorted.prefix(3).joined(separator: " · ")
        let extra = sorted.count - 3
        return extra > 0 ? "\(head) +\(extra)" : head
    }

    private func senderName(for actorId: String) -> String {
        actorId.isEmpty ? "Agent" : actorId
    }

    @ViewBuilder
    private func rowView(for message: SessionMessage) -> some View {
        if message.isSystem {
            MessageRowSystem(message: message)
        } else if message.senderActorId == actorId {
            MessageRowUser(message: message, senderName: senderName(for: message.senderActorId))
        } else {
            MessageRowAgent(
                message: message,
                senderName: senderName(for: message.senderActorId),
                modelLabel: modelLabel(for: message)
            )
        }
    }

    private func modelLabel(for message: SessionMessage) -> String? {
        guard let modelId = message.model, !modelId.isEmpty,
              let agent = primaryAgent
        else { return nil }
        return agent.availableModels.first(where: { $0.id == modelId })?.displayName ?? modelId
    }
}
