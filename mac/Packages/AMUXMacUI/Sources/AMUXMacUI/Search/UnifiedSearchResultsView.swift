import SwiftUI
import SwiftData
import AMUXCore

struct UnifiedSearchResultsView: View {
    let query: String
    @Binding var selectedSessionId: String?
    @Binding var selectedIdeaId: String?

    @Query private var sessions: [Session]
    @Query private var agents: [Agent]
    @Query private var messages: [SessionMessage]
    @Query private var ideas: [SessionIdea]

    private var sessionHits: [SessionHit] {
        let collab: [SessionHit] = sessions.compactMap { s in
            guard s.title.localizedCaseInsensitiveContains(query) else { return nil }
            return SessionHit(id: s.sessionId, title: s.title.isEmpty ? s.sessionId : s.title, subtitle: "session")
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

    private var ideaHits: [SessionIdea] {
        ideas.filter {
            $0.displayTitle.localizedCaseInsensitiveContains(query) ||
            $0.ideaDescription.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        List {
            if !sessionHits.isEmpty {
                Section("Sessions") {
                    ForEach(sessionHits) { hit in
                        Button { selectedSessionId = hit.id; selectedIdeaId = nil } label: {
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
                        Button { selectedSessionId = hit.sessionId; selectedIdeaId = nil } label: {
                            VStack(alignment: .leading) {
                                Text(hit.preview).lineLimit(2)
                                Text(hit.sessionId).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if !ideaHits.isEmpty {
                Section("Ideas") {
                    ForEach(ideaHits, id: \.ideaId) { idea in
                        Button { selectedIdeaId = idea.ideaId; selectedSessionId = nil } label: {
                            VStack(alignment: .leading) {
                                Text(idea.displayTitle)
                                Text(idea.statusLabel).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if sessionHits.isEmpty && messageHits.isEmpty && ideaHits.isEmpty {
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
