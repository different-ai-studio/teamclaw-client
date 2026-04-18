import SwiftUI
import SwiftData
import AMUXCore

struct SessionDetailView: View {
    let session: CollabSession
    let teamclawService: TeamclawService
    let actorId: String

    @Environment(\.modelContext) private var modelContext

    @Query private var allMessages: [SessionMessage]
    @Query private var allAgents: [Agent]
    @Query private var allWorkspaces: [Workspace]

    @State private var searchText: String = ""
    @State private var isPinned: Bool = false

    private var primaryAgent: Agent? {
        guard let id = session.primaryAgentId else { return nil }
        return allAgents.first(where: { $0.agentId == id })
    }

    private var workspaceName: String? {
        guard let agent = primaryAgent,
              let ws = allWorkspaces.first(where: { $0.workspaceId == agent.workspaceId })
        else { return nil }
        return ws.displayName.isEmpty ? nil : ws.displayName
    }

    private var agentLogoName: String? {
        guard let type = primaryAgent?.agentType else { return nil }
        switch type {
        case 1: return "ClaudeLogo"
        case 2: return "OpenCodeLogo"
        case 3: return "CodexLogo"
        default: return nil
        }
    }

    private var lastUpdated: Date {
        session.lastMessageAt ?? session.createdAt
    }

    var body: some View {
        let messages = allMessages
            .filter { $0.sessionId == session.sessionId }
            .filter { searchText.isEmpty || $0.content.localizedCaseInsensitiveContains(searchText) }
            .sorted { $0.createdAt < $1.createdAt }

        VStack(spacing: 0) {
            toolbarRow
            Divider()
            sessionHeaderRow
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if messages.isEmpty {
                        Text(searchText.isEmpty ? "No messages yet." : "No messages match \u{201C}\(searchText)\u{201D}.")
                            .foregroundStyle(.tertiary)
                            .padding(22)
                    } else {
                        ForEach(messages, id: \.messageId) { message in
                            rowView(for: message)
                        }
                        .padding(.bottom, 22)
                    }
                }
                .padding(.top, 12)
            }

            ComposerView(
                teamclawService: teamclawService,
                sessionId: session.sessionId,
                actorId: actorId,
                agent: primaryAgent
            )
        }
        .task(id: session.sessionId) {
            teamclawService.subscribeToSession(session.sessionId)
        }
    }

    // MARK: - Row 1: Toolbar

    private var toolbarRow: some View {
        HStack {
            HStack(spacing: 4) {
                pillButton(systemImage: isPinned ? "pin.fill" : "pin.fill", help: "Pin") {
                    isPinned.toggle()
                }
                .foregroundStyle(isPinned ? Color.accentColor : .primary)

                pillButton(systemImage: "archivebox.fill", help: "Archive") {
                    print("TODO(v1.1): archive for session \(session.sessionId)")
                }

                pillButton(systemImage: "person.badge.plus", help: "Add member") {
                    print("TODO(v1.1): add-member for session \(session.sessionId)")
                }

                pillButton(systemImage: "square.and.arrow.up", help: "Share") {
                    print("TODO(v1.1): share for session \(session.sessionId)")
                }
            }

            Spacer()

            searchField
                .frame(width: 200)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func pillButton(systemImage: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 28, height: 28)
                .background(Color.secondary.opacity(0.12), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            TextField("Search messages", text: $searchText)
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

    // MARK: - Row 2: Compact Session Header

    private var sessionHeaderRow: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(session.title.isEmpty ? "(untitled)" : session.title)
                .font(.system(size: 20, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 12)

            HStack(spacing: 8) {
                if let logo = agentLogoName {
                    Image(logo, bundle: .module)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 16, height: 16)
                }

                if let workspaceName {
                    Text(workspaceName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Text(SessionDetailView.formatTime(lastUpdated))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 10)
    }

    // Mirrors SessionRow.formatTime — duplicated here to keep the header
    // self-contained. If a third copy lands somewhere, lift this into a
    // shared helper.
    static func formatTime(_ date: Date) -> String {
        let seconds = Int(-date.timeIntervalSinceNow)
        if seconds < 60 { return "Just now" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        if seconds < 86400 { return "\(seconds / 3600)h" }
        if seconds < 604800 { return "\(seconds / 86400)d" }
        let formatter = DateFormatter()
        formatter.dateFormat = "MM/dd"
        return formatter.string(from: date)
    }

    // MARK: - Message rows

    private func senderName(for actorId: String) -> String {
        actorId.isEmpty ? "Agent" : actorId
    }

    @ViewBuilder
    private func rowView(for message: SessionMessage) -> some View {
        if message.isSystem {
            MessageRowSystem(message: message)
        } else if message.senderActorId == actorId {
            MessageRowUser(message: message, senderName: senderName(for: message.senderActorId))
        } else {
            MessageRowAgent(
                message: message,
                senderName: senderName(for: message.senderActorId),
                modelLabel: modelLabel(for: message)
            )
        }
    }

    private var modelLookup: [String: String] {
        guard let agent = primaryAgent else { return [:] }
        return Dictionary(uniqueKeysWithValues: agent.availableModels.map { ($0.id, $0.displayName) })
    }

    private func modelLabel(for message: SessionMessage) -> String? {
        guard let modelId = message.model, !modelId.isEmpty else { return nil }
        return modelLookup[modelId] ?? modelId
    }
}
