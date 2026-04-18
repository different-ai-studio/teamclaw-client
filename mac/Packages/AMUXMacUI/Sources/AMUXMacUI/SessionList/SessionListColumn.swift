import SwiftUI
import SwiftData
import AMUXCore

struct SessionListColumn: View {
    let memberFilter: String?
    let memberName: String?
    @Binding var selectedSessionId: String?
    var onNewSession: () -> Void = {}
    @Environment(\.openWindow) private var openWindow

    @Query(sort: \CollabSession.lastMessageAt, order: .reverse)
    private var sessions: [CollabSession]

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

    private func primaryAgent(for session: CollabSession) -> Agent? {
        guard let id = session.primaryAgentId else { return nil }
        return agentLookup[id]
    }

    private func workspaceName(for session: CollabSession) -> String {
        guard let agent = primaryAgent(for: session) else { return "" }
        return workspaceLookup[agent.workspaceId] ?? ""
    }

    private var visibleSessions: [CollabSession] {
        let sessionSenders = buildSessionSenders()
        let allowedIds = SessionFilters.sessionIdsInvolving(
            memberId: memberFilter,
            sessionSenders: sessionSenders
        )
        var list = sessions.filter { session in
            guard let allowed = allowedIds else { return true }
            return allowed.contains(session.sessionId)
        }
        if !searchText.isEmpty {
            let q = searchText.lowercased()
            list = list.filter { session in
                if session.title.lowercased().contains(q) { return true }
                if let agent = primaryAgent(for: session),
                   agent.sessionTitle.lowercased().contains(q) { return true }
                return false
            }
        }
        return list
    }

    private var unreadCount: Int {
        visibleSessions.reduce(0) { acc, session in
            acc + ((primaryAgent(for: session)?.hasUnread ?? false) ? 1 : 0)
        }
    }

    private var headerTitle: String {
        memberName ?? "Sessions"
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            if isSearchActive {
                searchField
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }

            Divider()

            if visibleSessions.isEmpty {
                ContentUnavailableView(
                    memberFilter == nil ? "No sessions yet" : "No sessions involving this member",
                    systemImage: "bubble.left.and.bubble.right"
                )
            } else {
                List(selection: $selectedSessionId) {
                    ForEach(SessionGrouping.grouped(visibleSessions)) { group in
                        Section {
                            ForEach(group.sessions, id: \.sessionId) { session in
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
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(headerTitle)
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundStyle(.primary)
                Text("\(unreadCount) unread")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 0) {
                iconButton(systemImage: "plus") {
                    onNewSession()
                }
                iconButton(systemImage: isEditing ? "checkmark.circle.fill" : "checkmark.circle",
                           highlighted: isEditing) {
                    isEditing.toggle()
                }
                iconButton(systemImage: "magnifyingglass",
                           highlighted: isSearchActive) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isSearchActive.toggle()
                        if !isSearchActive { searchText = "" }
                    }
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(Color.secondary.opacity(0.12), in: Capsule())
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private func iconButton(systemImage: String, highlighted: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(highlighted ? Color.accentColor : .primary)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func buildSessionSenders() -> [String: Set<String>] {
        var map: [String: Set<String>] = [:]
        for message in allMessages where !message.senderActorId.isEmpty {
            map[message.sessionId, default: []].insert(message.senderActorId)
        }
        return map
    }
}
