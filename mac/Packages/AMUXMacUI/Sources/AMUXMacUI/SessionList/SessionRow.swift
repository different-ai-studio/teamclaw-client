import SwiftUI
import AMUXCore

struct SessionRow: View {
    let session: CollabSession
    let primaryAgent: Agent?
    let workspaceName: String

    @State private var breathe = false

    private var isRunning: Bool { primaryAgent?.status == 2 }
    private var isUnread: Bool { primaryAgent?.hasUnread ?? false }

    private var displayTitle: String {
        if !session.title.isEmpty { return session.title }
        if let agent = primaryAgent, !agent.sessionTitle.isEmpty { return agent.sessionTitle }
        return "Untitled Session"
    }

    private var preview: String {
        if !session.lastMessagePreview.isEmpty { return session.lastMessagePreview }
        return primaryAgent?.currentPrompt ?? ""
    }

    private var avatarSeed: String { session.sessionId }

    private var avatarInitial: String {
        if let agent = primaryAgent {
            let name = agent.worktree.isEmpty ? agent.agentId : agent.worktree
            let lastComponent = name.split(separator: "/").last.map(String.init) ?? name
            return String(lastComponent.prefix(1)).uppercased()
        }
        let trimmed = session.title.trimmingCharacters(in: .whitespaces)
        return trimmed.first.map { String($0).uppercased() } ?? "?"
    }

    private var avatarColor: Color {
        let colors: [Color] = [.blue, .purple, .orange, .green, .pink, .teal, .indigo, .mint]
        let hash = avatarSeed.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return colors[abs(hash) % colors.count]
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

    private var rowDate: Date {
        session.lastMessageAt ?? session.createdAt
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
                    if primaryAgent == nil {
                        Circle()
                            .fill(Color.indigo.gradient)
                            .frame(width: 40, height: 40)
                        Image(systemName: "person.2.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(.white)
                    } else {
                        Circle()
                            .fill(avatarColor.gradient)
                            .frame(width: 40, height: 40)
                        Text(avatarInitial)
                            .font(.callout)
                            .fontWeight(.medium)
                            .foregroundStyle(.white)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(displayTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .foregroundStyle(.primary)

                if !preview.isEmpty {
                    Text(preview)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                HStack(spacing: 4) {
                    if let logo = agentLogoName {
                        Image(logo, bundle: .module)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 14, height: 14)
                    } else {
                        Image(systemName: "person.2")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if !workspaceName.isEmpty {
                        Text(workspaceName)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else if primaryAgent == nil {
                        Text("\(session.participantCount)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 0)

                    Text(SessionRow.formatTime(rowDate))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
        .padding(.vertical, 4)
    }

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
}
