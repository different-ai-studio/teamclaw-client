import SwiftUI
import SwiftData
import AMUXCore
import AMUXSharedUI

#if os(iOS)

// MARK: - SessionListContent

struct SessionListContent: View {
    @Bindable var viewModel: SessionListViewModel
    @Binding var navigationPath: [String]
    @Binding var isEditing: Bool
    @Binding var selectedIDs: Set<String>
    let teamclawService: TeamclawService?
    let actorId: String

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
                } else {
                    ContentUnavailableView("No Sessions", systemImage: "cpu",
                        description: Text("Start a new session to begin"))
                }
            } else {
                List {
                    ForEach(viewModel.groupedSessions) { group in
                        Section {
                            ForEach(group.items) { item in
                                sessionRow(item)
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
                    viewModel.reloadSessions(modelContext: modelContext)
                }
            }
        }
    }

    @ViewBuilder
    private func sessionRow(_ item: SessionItem) -> some View {
        switch item {
        case .agent(let agent):
            HStack(spacing: 10) {
                if isEditing {
                    Image(systemName: selectedIDs.contains(agent.agentId) ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selectedIDs.contains(agent.agentId) ? .blue : .secondary)
                        .font(.title3)
                        .onTapGesture { toggleSelection(agent.agentId) }
                }
                AgentRowView(agent: agent, workspaceName: workspaceName(for: agent))
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if isEditing {
                    toggleSelection(agent.agentId)
                } else {
                    navigationPath.append(agent.agentId)
                }
            }
            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))

        case .collab(let session):
            SessionRowView(session: session)
                .contentShape(Rectangle())
                .onTapGesture {
                    navigationPath.append("collab:\(session.sessionId)")
                }
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
        }
    }

    private func workspaceName(for agent: Agent) -> String {
        viewModel.workspaces.first(where: { $0.workspaceId == agent.workspaceId })?.displayName ?? ""
    }

    private func toggleSelection(_ id: String) {
        if selectedIDs.contains(id) { selectedIDs.remove(id) }
        else { selectedIDs.insert(id) }
    }
}

// MARK: - AgentRowView

struct AgentRowView: View {
    let agent: Agent
    let workspaceName: String

    @State private var breathe = false

    private var displayTitle: String {
        if !agent.sessionTitle.isEmpty { return agent.sessionTitle }
        return "Untitled Session"
    }

    private var isUnread: Bool { agent.hasUnread }
    private var isRunning: Bool { agent.status == 2 }

    private var avatarInitial: String {
        let name = agent.worktree.isEmpty ? agent.agentId : agent.worktree
        let lastComponent = name.split(separator: "/").last.map(String.init) ?? name
        return String(lastComponent.prefix(1)).uppercased()
    }

    private var avatarColor: Color {
        let colors: [Color] = [.blue, .purple, .orange, .green, .pink, .teal, .indigo, .mint]
        let hash = agent.agentId.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return colors[abs(hash) % colors.count]
    }

    private var agentLogoName: String {
        switch agent.agentType {
        case 1: "ClaudeLogo"
        case 2: "OpenCodeLogo"
        case 3: "CodexLogo"
        default: "ClaudeLogo"
        }
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
                        .fill(avatarColor.gradient)
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

                if !agent.currentPrompt.isEmpty {
                    Text(agent.currentPrompt)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                HStack(spacing: 4) {
                    Image(agentLogoName, bundle: .module)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 14, height: 14)

                    if !workspaceName.isEmpty {
                        Text(workspaceName)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 0)

                    Text(formatTime(agent.lastEventTime ?? agent.startedAt))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - SessionRowView

struct SessionRowView: View {
    let session: Session

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
                    .fill(Color.clear)
                    .frame(width: 8, height: 8)

                ZStack {
                    Circle()
                        .fill(Color.indigo.gradient)
                        .frame(width: 40, height: 40)
                    Image(systemName: "person.2.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.white)
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(session.title.isEmpty ? "Collab Session" : session.title)
                    .font(.body)
                    .fontWeight(.semibold)
                    .lineLimit(1)

                if !session.lastMessagePreview.isEmpty {
                    Text(session.lastMessagePreview)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                HStack(spacing: 4) {
                    Image(systemName: "person.2")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(session.participantCount)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Spacer(minLength: 0)

                    Text(formatTime(session.lastMessageAt ?? session.createdAt))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
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
