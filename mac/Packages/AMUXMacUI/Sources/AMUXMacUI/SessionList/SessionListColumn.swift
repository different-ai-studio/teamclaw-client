import SwiftUI
import SwiftData
import AMUXCore

struct SessionListColumn: View {
    let memberFilter: String?
    @Binding var selectedSessionId: String?
    @Environment(\.openWindow) private var openWindow

    @Query(sort: \CollabSession.lastMessageAt, order: .reverse)
    private var sessions: [CollabSession]

    @Query private var allMessages: [SessionMessage]

    var body: some View {
        let sessionSenders = buildSessionSenders()
        let allowedIds = SessionFilters.sessionIdsInvolving(
            memberId: memberFilter,
            sessionSenders: sessionSenders
        )
        let visible = sessions.filter { session in
            guard let allowed = allowedIds else { return true }
            return allowed.contains(session.sessionId)
        }

        if visible.isEmpty {
            ContentUnavailableView(
                memberFilter == nil ? "No sessions yet" : "No sessions involving this member",
                systemImage: "bubble.left.and.bubble.right"
            )
        } else {
            List(visible, id: \.sessionId, selection: $selectedSessionId) { session in
                SessionRow(
                    session: session,
                    participantSummary: participantSummary(
                        for: session.sessionId,
                        sessionSenders: sessionSenders
                    )
                )
                .tag(session.sessionId)
                .contextMenu {
                    Button("Open in New Window") {
                        openWindow(id: "session-detail", value: session.sessionId)
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    private func buildSessionSenders() -> [String: Set<String>] {
        var map: [String: Set<String>] = [:]
        for message in allMessages where !message.senderActorId.isEmpty {
            map[message.sessionId, default: []].insert(message.senderActorId)
        }
        return map
    }

    private func participantSummary(
        for sessionId: String,
        sessionSenders: [String: Set<String>]
    ) -> String {
        let senders = sessionSenders[sessionId] ?? []
        if senders.isEmpty { return "—" }
        let sorted = senders.sorted()
        let head = sorted.prefix(3).joined(separator: " · ")
        let extra = sorted.count - 3
        return extra > 0 ? "\(head) +\(extra)" : head
    }
}
