import SwiftUI
import SwiftData
import AMUXCore

struct SessionListColumn: View {
    let memberFilter: String?
    let memberName: String?
    let workspaceFilter: String?
    let workspaceName: String?
    @Binding var selectedSessionId: String?
    var onNewSession: () -> Void = {}
    @Environment(\.openWindow) private var openWindow

    @Query(sort: \Session.lastMessageAt, order: .reverse)
    private var sessions: [Session]

    @Query private var allMessages: [SessionMessage]
    @Query private var allAgents: [Agent]
    @Query private var allWorkspaces: [Workspace]

    @State private var isEditing = false
    @State private var isSearchActive = false
    @State private var searchText = ""

    private var agentLookup: [String: Agent] {
        Dictionary(uniqueKeysWithValues: allAgents.map { ($0.agentId, $0) })
    }

    private var workspaceLookup: [String: String] {
        Dictionary(uniqueKeysWithValues: allWorkspaces.map { ($0.workspaceId, $0.displayName) })
    }

    private func primaryAgent(for session: Session) -> Agent? {
        guard let id = session.primaryAgentId else { return nil }
        return agentLookup[id]
    }

    private func workspaceName(for session: Session) -> String {
        guard let agent = primaryAgent(for: session) else { return "" }
        return workspaceLookup[agent.workspaceId] ?? ""
    }

    private var visibleItems: [SessionListItem] {
        let sessionSenders = buildSessionSenders()
        let allowedIds = SessionFilters.sessionIdsInvolving(
            memberId: memberFilter,
            sessionSenders: sessionSenders
        )

        // Shared sessions first — filter by member + search.
        var items: [SessionListItem] = sessions.compactMap { session in
            if let allowed = allowedIds, !allowed.contains(session.sessionId) { return nil }
            if let workspaceFilter,
               primaryAgent(for: session)?.workspaceId != workspaceFilter {
                return nil
            }
            if !searchText.isEmpty {
                let matchesTitle = session.title.localizedCaseInsensitiveContains(searchText)
                let matchesAgent = primaryAgent(for: session)?
                    .sessionTitle.localizedCaseInsensitiveContains(searchText) ?? false
                guard matchesTitle || matchesAgent else { return nil }
            }
            return .collab(session)
        }

        // Solo agents: only those NOT already bound as a shared session's
        // primary agent (otherwise the same session renders twice). When a
        // member filter is active, keep agents out — they have no sender log
        // to match against.
        if allowedIds == nil {
            let boundAgentIds = Set(sessions.compactMap { $0.primaryAgentId })
            let soloAgents = allAgents.filter {
                !boundAgentIds.contains($0.agentId) &&
                (workspaceFilter == nil || $0.workspaceId == workspaceFilter)
            }
            for agent in soloAgents {
                if !searchText.isEmpty {
                    let matchesTitle = agent.sessionTitle.localizedCaseInsensitiveContains(searchText)
                    let matchesPrompt = agent.currentPrompt.localizedCaseInsensitiveContains(searchText)
                    let matchesWorktree = agent.worktree.localizedCaseInsensitiveContains(searchText)
                    guard matchesTitle || matchesPrompt || matchesWorktree else { continue }
                }
                items.append(.agent(agent))
            }
        }

        items.sort { $0.date > $1.date }
        return items
    }

    private var headerTitle: String {
        workspaceName ?? memberName ?? "Sessions"
    }

    var body: some View {
        VStack(spacing: 0) {
            if isSearchActive {
                searchField
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
                    .padding(.bottom, 8)
            }

            if visibleItems.isEmpty {
                ContentUnavailableView(
                    memberFilter == nil ? "No sessions yet" : "No sessions involving this member",
                    systemImage: "bubble.left.and.bubble.right"
                )
            } else {
                List(selection: $selectedSessionId) {
                    ForEach(SessionGrouping.grouped(visibleItems)) { group in
                        Section {
                            ForEach(group.items) { item in
                                switch item {
                                case .collab(let session):
                                    SessionRow(
                                        session: session,
                                        primaryAgent: primaryAgent(for: session),
                                        workspaceName: workspaceName(for: session)
                                    )
                                    .tag(session.sessionId)
                                    .contextMenu {
                                        Button("Open in New Window") {
                                            openWindow(id: "session-detail", value: session.sessionId)
                                        }
                                    }
                                case .agent(let agent):
                                    AgentSessionRow(
                                        agent: agent,
                                        workspaceName: workspaceLookup[agent.workspaceId] ?? ""
                                    )
                                    .tag(agent.agentId)
                                    .contextMenu {
                                        Button("Open in New Window") {
                                            openWindow(id: "session-detail", value: agent.agentId)
                                        }
                                    }
                                }
                            }
                        } header: {
                            Text(group.title)
                                .font(.subheadline)
                                .fontWeight(.semibold)
                                .foregroundStyle(.secondary)
                                .textCase(nil)
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle(headerTitle)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    onNewSession()
                } label: {
                    Label("New Session", systemImage: "plus")
                }
                .keyboardShortcut("n", modifiers: .command)
                .help("New Session (⌘N)")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isEditing.toggle()
                } label: {
                    Label("Edit", systemImage: isEditing ? "checkmark.circle.fill" : "checkmark.circle")
                }
                .help("Edit")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isSearchActive.toggle()
                        if !isSearchActive { searchText = "" }
                    }
                } label: {
                    Label("Search", systemImage: "magnifyingglass")
                }
                .keyboardShortcut("f", modifiers: .command)
                .help("Search (⌘F)")
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            TextField("Search", text: $searchText)
                .textFieldStyle(.plain)
                .font(.subheadline)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .glassEffect(in: Capsule())
    }

    private func buildSessionSenders() -> [String: Set<String>] {
        var map: [String: Set<String>] = [:]
        for message in allMessages where !message.senderActorId.isEmpty {
            map[message.sessionId, default: []].insert(message.senderActorId)
        }
        return map
    }
}
