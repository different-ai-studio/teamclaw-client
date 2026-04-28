import SwiftUI
import SwiftData
import AMUXCore
import AMUXSharedUI

#if os(iOS)

// MARK: - SessionListContent

struct SessionListContent: View {
    @Bindable var viewModel: SessionListViewModel
    let refreshSessionsFromBackend: () async -> Void
    @Binding var navigationPath: [String]
    @Binding var isEditing: Bool
    @Binding var selectedIDs: Set<String>
    let teamclawService: TeamclawService?
    let actorId: String
    /// True when the current user has zero accessible agents in this team.
    /// The empty-state copy switches to an invite-first-agent CTA in that case.
    let noAccessibleAgent: Bool
    /// Tap handler for the empty-state CTA. Caller presents an invite sheet.
    /// Pass nil to hide the action (e.g. when no ActorStore is available yet).
    let onInviteFirstAgent: (() -> Void)?

    @Environment(\.modelContext) private var modelContext

    private var hasContent: Bool { !viewModel.groupedSessions.isEmpty }
    private var hasActiveSearch: Bool {
        !viewModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        Group {
            if !hasContent && viewModel.isLoading {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Loading sessions…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !hasContent {
                if hasActiveSearch {
                    ContentUnavailableView.search(text: viewModel.searchText)
                } else if noAccessibleAgent {
                    ContentUnavailableView {
                        Label("Invite your first agent", systemImage: "cpu")
                    } description: {
                        Text("You don't have access to any agent in this team yet. Invite one to start a session.")
                    } actions: {
                        Button {
                            onInviteFirstAgent?()
                        } label: {
                            Text("Invite agent")
                                .fontWeight(.semibold)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                        }
                        .glassProminentButtonStyle()
                        .accessibilityIdentifier("sessions.inviteFirstAgentButton")
                    }
                } else {
                    ContentUnavailableView("No Sessions", systemImage: "cpu",
                        description: Text("Start a new session to begin"))
                }
            } else {
                List {
                    ForEach(viewModel.groupedSessions) { group in
                        Section {
                            ForEach(group.items) { session in
                                sessionRow(session)
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
                .listStyle(.plain)
                .refreshable {
                    await refreshSessionsFromBackend()
                }
            }
        }
    }

    @ViewBuilder
    private func sessionRow(_ session: Session) -> some View {
        let cached = cachedAgentRuntime(for: session)
        let runtime = liveRuntime(for: cached)
        HStack(spacing: 10) {
            if isEditing {
                Image(systemName: selectedIDs.contains(session.sessionId) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selectedIDs.contains(session.sessionId) ? .blue : .secondary)
                    .font(.title3)
                    .onTapGesture { toggleSelection(session.sessionId) }
            }
            AgentRowView(
                session: session,
                runtime: runtime,
                cachedRuntime: cached,
                workspaceName: workspaceName(runtime: runtime, cached: cached)
            )
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if isEditing {
                toggleSelection(session.sessionId)
            } else {
                navigationPath.append("session:\(session.sessionId)")
            }
        }
        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button {
                session.isArchived = true
                try? modelContext.save()
            } label: {
                Label("Archive", systemImage: "archivebox.fill")
            }
            .tint(.red)

            Button {
                session.isPinned.toggle()
                try? modelContext.save()
            } label: {
                Label(session.isPinned ? "Unpin" : "Pin",
                      systemImage: session.isPinned ? "pin.slash.fill" : "pin.fill")
            }
            .tint(.indigo)
        }
    }

    /// Most-recently-updated `agent_runtimes` row that serves this session.
    /// Provides backend type + workspace + status when MQTT is offline.
    private func cachedAgentRuntime(for session: Session) -> CachedAgentRuntime? {
        viewModel.cachedAgentRuntimes
            .filter { $0.sessionId == session.sessionId }
            .max(by: { $0.updatedAt < $1.updatedAt })
    }

    /// Bridge from a Supabase `agent_runtimes` row to its MQTT-published
    /// `Runtime` snapshot via `backend_session_id`. Nil when the daemon is
    /// offline or hasn't published yet.
    private func liveRuntime(for cached: CachedAgentRuntime?) -> Runtime? {
        guard let bridge = cached?.backendSessionId, !bridge.isEmpty else { return nil }
        return viewModel.runtimes.first(where: { $0.runtimeId == bridge })
    }

    private func workspaceName(runtime: Runtime?, cached: CachedAgentRuntime?) -> String {
        guard let id = cached?.workspaceId, !id.isEmpty else { return "" }
        return viewModel.workspaces.first(where: { $0.workspaceId == id })?.displayName ?? ""
    }

    private func toggleSelection(_ id: String) {
        if selectedIDs.contains(id) { selectedIDs.remove(id) }
        else { selectedIDs.insert(id) }
    }
}

// MARK: - AgentRowView

struct AgentRowView: View {
    let session: Session
    let runtime: Runtime?
    let cachedRuntime: CachedAgentRuntime?
    let workspaceName: String

    @State private var breathe = false

    init(
        session: Session,
        runtime: Runtime? = nil,
        cachedRuntime: CachedAgentRuntime? = nil,
        workspaceName: String = ""
    ) {
        self.session = session
        self.runtime = runtime
        self.cachedRuntime = cachedRuntime
        self.workspaceName = workspaceName
    }

    // Supabase-first row resolution. The MQTT live `Runtime` is consulted
    // ONLY for the breathing-dot running state and the unread hint — every
    // other field reads off `Session` + `CachedAgentRuntime` so the row is
    // stable when the daemon is offline.

    private var displayTitle: String {
        session.title.isEmpty ? "Untitled Session" : session.title
    }

    private var lastMessage: String { session.lastMessagePreview }

    private var isUnread: Bool { runtime?.hasUnread ?? false }

    /// Live MQTT status (== 2) wins; otherwise the Supabase-cached row's
    /// status drives the breathing dot when the daemon is offline.
    private var isRunning: Bool {
        if let runtime { return runtime.status == 2 }
        return cachedRuntime?.status == "running"
    }

    private var avatarSeed: String { session.primaryAgentId ?? session.sessionId }

    private var avatarInitial: String {
        let source = session.title.isEmpty ? session.sessionId : session.title
        let lastComponent = source.split(separator: "/").last.map(String.init) ?? source
        return lastComponent.isEmpty ? "·" : String(lastComponent.prefix(1)).uppercased()
    }

    /// Lower-saturation palette: each base color is mixed with white to
    /// reduce vibrance so the avatar doesn't dominate the row.
    private var avatarColor: Color {
        let palette: [Color] = [.blue, .purple, .orange, .green, .pink, .teal, .indigo, .mint]
        let hash = avatarSeed.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return palette[abs(hash) % palette.count].mix(with: .white, by: 0.30)
    }

    private var agentLogoName: String? {
        switch cachedRuntime?.backendType {
        case "claude": return "ClaudeLogo"
        case "opencode": return "OpenCodeLogo"
        case "codex": return "CodexLogo"
        default: return nil
        }
    }

    private var rowTimestamp: Date {
        session.lastMessageAt ?? session.createdAt
    }

    private func formatTime(_ date: Date) -> String {
        let seconds = Int(-date.timeIntervalSinceNow)
        if seconds < 60 { return "Just now" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        if seconds < 86400 { return "\(seconds / 3600)h" }
        if seconds < 604800 { return "\(seconds / 86400)d" }
        let formatter = DateFormatter()
        formatter.dateFormat = "MM/dd"
        return formatter.string(from: date)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            HStack(spacing: 6) {
                Circle()
                    .fill(isRunning ? Color.red : isUnread ? Color.blue : Color.clear)
                    .frame(width: 8, height: 8)
                    .opacity(isRunning ? (breathe ? 0.3 : 1.0) : 1.0)
                    .animation(
                        isRunning
                            ? .easeInOut(duration: 1.2).repeatForever(autoreverses: true)
                            : .default,
                        value: breathe
                    )
                    .onAppear { breathe = true }

                ZStack {
                    Circle()
                        .fill(avatarColor)
                        .frame(width: 40, height: 40)
                    Text(avatarInitial)
                        .font(.callout)
                        .fontWeight(.medium)
                        .foregroundStyle(.white)
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(displayTitle)
                    .font(.body)
                    .fontWeight(.semibold)
                    .lineLimit(1)

                if !lastMessage.isEmpty {
                    Text(lastMessage)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                HStack(spacing: 4) {
                    let hasLeadingChip = agentLogoName != nil || !workspaceName.isEmpty

                    if let logo = agentLogoName {
                        Image(logo, bundle: .module)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 14, height: 14)
                    }

                    if !workspaceName.isEmpty {
                        Text(workspaceName)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    if session.participantCount > 1 {
                        if hasLeadingChip {
                            Text("·")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Image(systemName: "person.2")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("\(session.participantCount)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 0)

                    Text(formatTime(rowTimestamp))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .alignmentGuide(.listRowSeparatorLeading) { d in d[.leading] }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Transition Modifiers

struct ZoomTransitionModifier: ViewModifier {
    let sourceID: String
    let namespace: Namespace.ID
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.navigationTransition(.zoom(sourceID: sourceID, in: namespace))
        } else { content }
    }
}

struct MatchedTransitionSourceModifier: ViewModifier {
    let sourceID: String
    let namespace: Namespace.ID
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.matchedTransitionSource(id: sourceID, in: namespace)
        } else { content }
    }
}

#endif
