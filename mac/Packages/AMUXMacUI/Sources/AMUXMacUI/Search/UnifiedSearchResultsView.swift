import SwiftUI
import SwiftData
import AMUXCore

struct UnifiedSearchResultsView: View {
    let query: String
    @Binding var selectedSessionId: String?
    @Binding var selectedTaskId: String?

    @Query private var sessions: [CollabSession]
    @Query private var agents: [Agent]
    @Query private var messages: [SessionMessage]
    @Query private var tasks: [WorkItem]

    private var sessionHits: [SessionHit] {
        let collab: [SessionHit] = sessions.compactMap { s in
            guard s.title.localizedCaseInsensitiveContains(query) else { return nil }
            return SessionHit(id: s.sessionId, title: s.title.isEmpty ? s.sessionId : s.title, subtitle: "collab")
        }
        let agentHits: [SessionHit] = agents.compactMap { a in
            guard a.sessionTitle.localizedCaseInsensitiveContains(query) else { return nil }
            return SessionHit(id: a.agentId, title: a.sessionTitle.isEmpty ? a.agentId : a.sessionTitle, subtitle: "agent")
        }
        return collab + agentHits
    }

    private var messageHits: [MessageHit] {
        messages.compactMap { m in
            guard !m.content.isEmpty else { return nil }
            guard m.content.localizedCaseInsensitiveContains(query) else { return nil }
            return MessageHit(id: m.messageId, sessionId: m.sessionId, preview: String(m.content.prefix(140)))
        }
    }

    private var taskHits: [WorkItem] {
        tasks.filter {
            $0.displayTitle.localizedCaseInsensitiveContains(query) ||
            $0.itemDescription.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        List {
            if !sessionHits.isEmpty {
                Section("Sessions") {
                    ForEach(sessionHits) { hit in
                        Button { selectedSessionId = hit.id; selectedTaskId = nil } label: {
                            VStack(alignment: .leading) {
                                Text(hit.title)
                                Text(hit.subtitle).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if !messageHits.isEmpty {
                Section("Messages") {
                    ForEach(messageHits) { hit in
                        Button { selectedSessionId = hit.sessionId; selectedTaskId = nil } label: {
                            VStack(alignment: .leading) {
                                Text(hit.preview).lineLimit(2)
                                Text(hit.sessionId).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if !taskHits.isEmpty {
                Section("Tasks") {
                    ForEach(taskHits, id: \.workItemId) { task in
                        Button { selectedTaskId = task.workItemId; selectedSessionId = nil } label: {
                            VStack(alignment: .leading) {
                                Text(task.displayTitle)
                                Text(task.statusLabel).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if sessionHits.isEmpty && messageHits.isEmpty && taskHits.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
    }

    struct SessionHit: Identifiable {
        let id: String
        let title: String
        let subtitle: String
    }
    struct MessageHit: Identifiable {
        let id: String
        let sessionId: String
        let preview: String
    }
}
