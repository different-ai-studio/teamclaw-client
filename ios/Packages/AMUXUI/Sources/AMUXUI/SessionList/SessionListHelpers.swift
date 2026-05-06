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
    /// `Runtime` snapshot via `runtime_id` (the daemon's 8-char id, distinct
    /// from `backend_session_id`'s 36-char ACP session id). Nil when the
    /// daemon is offline or hasn't published yet.
    private func liveRuntime(for cached: CachedAgentRuntime?) -> Runtime? {
        guard let bridge = cached?.runtimeId, !bridge.isEmpty else { return nil }
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

    private var displayTitle: String {
        session.title.isEmpty ? "Untitled Session" : session.title
    }

    private var lastMessage: String { session.lastMessagePreview }
    private var isUnread: Bool { runtime?.hasUnread ?? false }

    private var isRunning: Bool {
        if let runtime { return runtime.status == 2 }
        return cachedRuntime?.status == "running"
    }
    private var isStarting: Bool {
        if let runtime { return runtime.status == 1 }
        return cachedRuntime?.status == "starting"
    }
    private var isStopped: Bool {
        if let runtime { return runtime.status == 5 }
        return cachedRuntime?.status == "stopped" || cachedRuntime?.status == "failed"
    }

    private var statusLabel: String {
        if let runtime, runtime.status != 0 { return runtime.statusLabel }
        if let raw = cachedRuntime?.status, !raw.isEmpty {
            return raw.prefix(1).uppercased() + raw.dropFirst()
        }
        return ""
    }

    private var statusForeground: Color {
        if isRunning  { return Color(red: 0x1B/255, green: 0x7A/255, blue: 0x3D/255) }
        if isStarting { return Color(red: 0xA2/255, green: 0x58/255, blue: 0x0B/255) }
        return .secondary
    }

    private var statusDotColor: Color {
        if isRunning  { return Color(red: 0x34/255, green: 0xC7/255, blue: 0x59/255) }
        if isStarting { return Color(red: 0xFF/255, green: 0x95/255, blue: 0x00/255) }
        if isStopped  { return Color.black.opacity(0.25) }
        return Color(.systemGray)
    }

    /// Tinted background + foreground + 2-letter glyph keyed off the daemon
    /// backend type. Falls back to a neutral chip with the title's initial
    /// when the row hasn't resolved a CachedAgentRuntime yet.
    private struct AgentBadge {
        let background: Color
        let foreground: Color
        let glyph: String
    }

    private var agentBadge: AgentBadge {
        switch cachedRuntime?.backendType {
        case "claude":
            return AgentBadge(
                background: Color(red: 0xFC/255, green: 0xED/255, blue: 0xE3/255),
                foreground: Color(red: 0xC2/255, green: 0x4F/255, blue: 0x1F/255),
                glyph: "CC"
            )
        case "opencode":
            return AgentBadge(
                background: Color(red: 0xE4/255, green: 0xF1/255, blue: 0xFB/255),
                foreground: Color(red: 0x1B/255, green: 0x6B/255, blue: 0xB8/255),
                glyph: "OC"
            )
        case "codex":
            return AgentBadge(
                background: Color(red: 0xEF/255, green: 0xEA/255, blue: 0xFB/255),
                foreground: Color(red: 0x5B/255, green: 0x45/255, blue: 0xA8/255),
                glyph: "CX"
            )
        default:
            return AgentBadge(
                background: Color(.tertiarySystemFill),
                foreground: .secondary,
                glyph: fallbackGlyph
            )
        }
    }

    private var fallbackGlyph: String {
        let source = session.title.isEmpty ? session.sessionId : session.title
        let last = source.split(separator: "/").last.map(String.init) ?? source
        return last.isEmpty ? "·" : String(last.prefix(1)).uppercased()
    }

    private var rowTimestamp: Date {
        session.lastMessageAt ?? session.createdAt
    }

    private func formatTime(_ date: Date) -> String {
        let seconds = Int(-date.timeIntervalSinceNow)
        if seconds < 60     { return "now" }
        if seconds < 3600   { return "\(seconds / 60)m" }
        if seconds < 86400  { return "\(seconds / 3600)h" }
        if seconds < 604800 { return "\(seconds / 86400)d" }
        let f = DateFormatter()
        f.dateFormat = "MM/dd"
        return f.string(from: date)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                badgeView
                Text(displayTitle)
                    .font(.body)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .foregroundStyle(isStopped ? .secondary : .primary)
                Spacer(minLength: 4)
                if isUnread {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 7, height: 7)
                }
                Text(formatTime(rowTimestamp))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !lastMessage.isEmpty {
                Text(lastMessage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.leading, badgeIndent)
            }

            metaStrip
                .padding(.leading, badgeIndent)
        }
        .padding(.vertical, 6)
        .alignmentGuide(.listRowSeparatorLeading) { _ in Self.badgeIndent }
    }

    private static let badgeIndent: CGFloat = 38
    private var badgeIndent: CGFloat { Self.badgeIndent }

    private var badgeView: some View {
        let badge = agentBadge
        return HStack(spacing: 5) {
            Circle()
                .fill(statusDotColor)
                .frame(width: 5, height: 5)
                .opacity(isRunning ? (breathe ? 0.35 : 1.0) : 1.0)
                .animation(
                    isRunning
                        ? .easeInOut(duration: 1.4).repeatForever(autoreverses: true)
                        : .default,
                    value: breathe
                )
                .onAppear { if isRunning { breathe = true } }
            Text(badge.glyph)
                .font(.system(size: 11, weight: .bold))
                .tracking(0.2)
                .foregroundStyle(badge.foreground)
        }
        .padding(.horizontal, 7)
        .frame(height: 22)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(badge.background)
        )
    }

    @ViewBuilder
    private var metaStrip: some View {
        HStack(spacing: 8) {
            if !workspaceName.isEmpty {
                Text(workspaceName)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if !workspaceName.isEmpty && !statusLabel.isEmpty {
                Circle()
                    .fill(Color.secondary.opacity(0.3))
                    .frame(width: 3, height: 3)
            }

            if !statusLabel.isEmpty {
                Text(statusLabel)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(statusForeground)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            if session.participantCount > 1 {
                HStack(spacing: 3) {
                    Image(systemName: "person.2.fill")
                        .font(.system(size: 10))
                    Text("\(session.participantCount)")
                        .font(.caption)
                        .monospacedDigit()
                }
                .foregroundStyle(.secondary)
            }
        }
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
