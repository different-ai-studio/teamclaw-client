import SwiftUI
import SwiftData
import AMUXCore

struct SessionDetailView: View {
    let session: CollabSession
    let teamclawService: TeamclawService
    let actorId: String

    @Environment(\.modelContext) private var modelContext

    @Query private var allMessages: [SessionMessage]

    var body: some View {
        let messages = allMessages
            .filter { $0.sessionId == session.sessionId }
            .sorted { $0.createdAt < $1.createdAt }

        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                DetailHeaderView(session: session, participantSummary: participantSummary(messages))

                if messages.isEmpty {
                    Text("No messages yet.")
                        .foregroundStyle(.tertiary)
                        .padding(22)
                } else {
                    Text("\(messages.count) message(s) — rendering coming in next steps")
                        .foregroundStyle(.tertiary)
                        .padding(22)
                }
            }
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
}
