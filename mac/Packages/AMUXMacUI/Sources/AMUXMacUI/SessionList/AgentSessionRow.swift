import SwiftUI
import AMUXCore

/// Session list row for a solo Agent (one not bound to any shared session).
/// Structure mirrors `SessionRow` so the two cases look visually consistent
/// when both appear in the same list.
struct AgentSessionRow: View {
    let agent: Agent
    let workspaceName: String

    @State private var breathe = false

    private var isRunning: Bool { agent.status == 2 }
    private var isUnread: Bool { agent.hasUnread }

    private var displayTitle: String {
        if !agent.sessionTitle.isEmpty { return agent.sessionTitle }
        if !agent.currentPrompt.isEmpty { return agent.currentPrompt }
        return "Untitled Session"
    }

    private var preview: String {
        // If the title already surfaces the prompt, suppress it from the
        // preview row to avoid the same text appearing twice stacked.
        if displayTitle == agent.currentPrompt { return "" }
        return agent.currentPrompt
    }

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

    private var agentLogoName: String? {
        switch agent.agentType {
        case 1: return "ClaudeLogo"
        case 2: return "OpenCodeLogo"
        case 3: return "CodexLogo"
        default: return nil
        }
    }

    private var rowDate: Date { agent.lastEventTime ?? agent.startedAt }

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
                        Image(systemName: "cpu")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if !workspaceName.isEmpty {
                        Text(workspaceName)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
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
}
