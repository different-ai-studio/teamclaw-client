import SwiftUI
import AMUXCore

/// Small pill that shows the current agent status (Starting / Active / Idle /
/// Error / Stopped). Because Agent is a SwiftData @Model, the pill re-renders
/// automatically when AgentDetailViewModel writes a new status in response to
/// an Amux_AcpStatusChange event.
struct AgentStatusPill: View {
    let agent: Agent

    @State private var breathe = false

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
                .opacity(agent.isActive ? (breathe ? 0.35 : 1.0) : 1.0)
                .animation(
                    agent.isActive
                        ? .easeInOut(duration: 1.2).repeatForever(autoreverses: true)
                        : .default,
                    value: breathe
                )
                .onAppear { breathe = true }
            Text(agent.statusLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(color.opacity(0.12), in: Capsule())
    }

    private var color: Color {
        switch agent.status {
        case 1: return .yellow   // Starting
        case 2: return .green    // Active
        case 3: return .secondary // Idle
        case 4: return .red      // Error
        case 5: return .gray     // Stopped
        default: return .secondary
        }
    }
}
