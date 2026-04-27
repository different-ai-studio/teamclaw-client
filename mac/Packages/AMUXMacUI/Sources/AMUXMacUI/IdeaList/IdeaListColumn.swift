import SwiftUI
import SwiftData
import AMUXCore

struct IdeaListColumn: View {
    @Binding var selectedIdeaId: String?
    let teamclawService: TeamclawService?
    let archivedVisible: Bool
    let workspaceFilter: String?
    let workspaceName: String?

    @Environment(\.openWindow) private var openWindow

    @Query(filter: #Predicate<SessionIdea> { !$0.archived })
    private var allIdeas: [SessionIdea]
    @Query(filter: #Predicate<SessionIdea> { $0.archived }, sort: \SessionIdea.createdAt, order: .reverse)
    private var archivedIdeas: [SessionIdea]
    @Query private var allSessions: [Session]
    @Query private var allAgents: [Agent]

    @State private var archivedExpanded: Bool = false

    var body: some View {
        let sortedIdeas = filteredIdeas(allIdeas).sorted(by: IdeaListColumn.compare)
        let visibleArchivedIdeas = filteredIdeas(archivedIdeas)

        VStack(spacing: 0) {
            if sortedIdeas.isEmpty && (!archivedVisible || visibleArchivedIdeas.isEmpty) {
                ContentUnavailableView("No ideas yet", systemImage: "lightbulb")
            } else {
                List(selection: $selectedIdeaId) {
                    ForEach(sortedIdeas, id: \.ideaId) { idea in
                        IdeaRow(
                            idea: idea,
                            sessionTitle: sessionTitle(for: idea.sessionId),
                            teamclawService: teamclawService
                        )
                        .tag(idea.ideaId)
                    }
                    if archivedVisible && !visibleArchivedIdeas.isEmpty {
                        Section {
                            DisclosureGroup("Archived (\(visibleArchivedIdeas.count))", isExpanded: $archivedExpanded) {
                                ForEach(visibleArchivedIdeas, id: \.ideaId) { idea in
                                    IdeaRow(
                                        idea: idea,
                                        sessionTitle: sessionTitle(for: idea.sessionId),
                                        teamclawService: teamclawService
                                    )
                                    .tag(idea.ideaId)
                                    .opacity(0.55)
                                    .contextMenu {
                                        Button("Unarchive") {
                                            let id = idea.ideaId
                                            let sid = idea.sessionId
                                            Task { await teamclawService?.archiveIdea(ideaId: id, sessionId: sid, archived: false) }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle(workspaceName ?? "Ideas")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    openWindow(
                        id: "amux.ideaEditor",
                        value: IdeaEditorInput(presetWorkspaceId: workspaceFilter)
                    )
                } label: {
                    Label("New Idea", systemImage: "plus")
                }
                .keyboardShortcut("n", modifiers: .command)
                .help("New Idea (⌘N)")
            }
        }
    }

    private func sessionTitle(for id: String) -> String? {
        allSessions.first(where: { $0.sessionId == id })?.title
    }

    private func filteredIdeas(_ ideas: [SessionIdea]) -> [SessionIdea] {
        guard let workspaceFilter else { return ideas }
        let sessionLookup = Dictionary(uniqueKeysWithValues: allSessions.map { ($0.sessionId, $0) })
        let agentLookup = Dictionary(uniqueKeysWithValues: allAgents.map { ($0.agentId, $0) })
        return ideas.filter { idea in
            if idea.workspaceId == workspaceFilter {
                return true
            }
            guard let session = sessionLookup[idea.sessionId],
                  let agentId = session.primaryAgentId,
                  let agent = agentLookup[agentId] else {
                return false
            }
            return agent.workspaceId == workspaceFilter
        }
    }

    /// Sort: open first, then in_progress, then done. Within each, newest first.
    static func compare(lhs: SessionIdea, rhs: SessionIdea) -> Bool {
        let order: [String: Int] = ["open": 0, "in_progress": 1, "done": 2]
        let lhsRank = order[lhs.status, default: 3]
        let rhsRank = order[rhs.status, default: 3]
        if lhsRank != rhsRank { return lhsRank < rhsRank }
        return lhs.createdAt > rhs.createdAt
    }
}
