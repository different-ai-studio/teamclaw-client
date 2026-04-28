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
        let runtime = primaryRuntime(for: session)
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
                workspaceName: workspaceName(for: runtime)
            )
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if isEditing {
                toggleSelection(session.sessionId)
            } else {
                navigationPath.append("collab:\(session.sessionId)")
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

    private func primaryRuntime(for session: Session) -> Runtime? {
        guard let agentId = session.primaryAgentId, !agentId.isEmpty else { return nil }
        return viewModel.runtimes.first(where: { $0.runtimeId == agentId })
    }

    private func workspaceName(for runtime: Runtime?) -> String {
        guard let runtime else { return "" }
        return viewModel.workspaces.first(where: { $0.workspaceId == runtime.workspaceId })?.displayName ?? ""
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
    let workspaceName: String

    @State private var breathe = false

    private var displayTitle: String {
        if !session.title.isEmpty { return session.title }
        if let runtime, !runtime.sessionTitle.isEmpty { return runtime.sessionTitle }
        return "Untitled Session"
    }

    /// Last message: prefer the LLM's most recent output, fall back to the
    /// pending user prompt (so a session that only has a kicked-off prompt
    /// still shows useful preview text), and finally to the Supabase preview.
    private var lastMessage: String {
        if let runtime {
            if !runtime.lastOutputSummary.isEmpty { return runtime.lastOutputSummary }
            if !runtime.currentPrompt.isEmpty { return runtime.currentPrompt }
        }
        return session.lastMessagePreview
    }

    private var isUnread: Bool { runtime?.hasUnread ?? false }
    private var isRunning: Bool { runtime?.status == 2 }

    private var avatarSeed: String { session.primaryAgentId ?? session.sessionId }

    private var avatarInitial: String {
        let source: String = {
            if let runtime, !runtime.worktree.isEmpty { return runtime.worktree }
            if !session.title.isEmpty { return session.title }
            return session.sessionId
        }()
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
        guard let agentType = runtime?.agentType else { return nil }
        switch agentType {
        case 1: return "ClaudeLogo"
        case 2: return "OpenCodeLogo"
        case 3: return "CodexLogo"
        default: return nil
        }
    }

    private var rowTimestamp: Date {
        if let runtime, let last = runtime.lastEventTime { return last }
        return session.lastMessageAt ?? session.createdAt
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
