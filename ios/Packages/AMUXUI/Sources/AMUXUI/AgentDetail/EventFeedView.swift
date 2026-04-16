import SwiftUI
import AMUXCore

// MARK: - EventBubbleView

public struct EventBubbleView: View {
    let event: AgentEvent
    let onGrant: ((String) -> Void)?
    let onDeny: ((String) -> Void)?

    @Environment(\.horizontalSizeClass) private var sizeClass

    public init(event: AgentEvent, onGrant: ((String) -> Void)? = nil, onDeny: ((String) -> Void)? = nil) {
        self.event = event
        self.onGrant = onGrant
        self.onDeny = onDeny
    }

    public var body: some View {
        switch event.eventType {
        case "user_prompt":
            userBubble
        case "output":
            assistantBubble
        case "thinking":
            thinkingBlock
        case "tool_use":
            toolUseBlock
        case "tool_result":
            EmptyView()
        case "error":
            errorBlock
        case "permission_request":
            PermissionBannerView(
                toolName: event.toolName ?? "",
                description: event.text ?? "",
                requestId: event.toolId ?? "",
                isResolved: event.isComplete == true,
                wasGranted: event.success,
                onGrant: event.isComplete == true ? nil : onGrant,
                onDeny: event.isComplete == true ? nil : onDeny
            )
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
        case "todo_update":
            TodoListView(text: event.text ?? "")
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
        default:
            EmptyView()
        }
    }

    // MARK: - User Bubble (blue, right-aligned)

    private var userBubble: some View {
        HStack {
            Spacer()
            Text(event.text ?? "")
                .font(.subheadline)
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.blue)
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .frame(maxWidth: sizeClass == .regular ? 500 : 260, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }

    // MARK: - Assistant Bubble (gray, left-aligned, markdown)

    private var assistantBubble: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                MarkdownRenderer(content: event.text ?? "")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 18))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }

    // MARK: - Thinking Block

    private var thinkingBlock: some View {
        ThinkingBlockView(text: event.text ?? "")
    }

    // MARK: - Tool Use

    private var toolUseBlock: some View {
        let status: String = {
            if event.isComplete == true {
                return (event.success == true) ? "completed" : "failed"
            }
            return "running"
        }()
        return ToolCallView(
            toolName: event.toolName ?? "Unknown",
            toolId: event.toolId ?? "",
            description: event.text ?? "",
            status: status
        )
        .padding(.horizontal, 16)
        .padding(.vertical, 2)
    }

    // MARK: - Tool Result

    private var toolResultBlock: some View {
        ToolCallView(
            toolName: "",
            toolId: event.toolId ?? "",
            description: event.text ?? "",
            status: event.success == true ? "completed" : "failed"
        )
        .padding(.horizontal, 16)
        .padding(.vertical, 2)
    }

    // MARK: - Error

    private var errorBlock: some View {
        ErrorBlockView(message: event.text ?? "Unknown error")
    }
}

// MARK: - ThinkingBlockView

struct ThinkingBlockView: View {
    let text: String
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .font(.caption2)
                    Image(systemName: "brain")
                        .font(.caption)
                    Text("Thinking")
                        .font(.caption)
                        .fontWeight(.medium)
                    if !isExpanded {
                        Text(text.prefix(60) + (text.count > 60 ? "…" : ""))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            if isExpanded {
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 10))
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }
}

// MARK: - ErrorBlockView

struct ErrorBlockView: View {
    let message: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }
}

// MARK: - TypingIndicatorView

struct TypingIndicatorView: View {
    @State private var phase = 0.0

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3) { i in
                Circle()
                    .fill(Color.secondary)
                    .frame(width: 8, height: 8)
                    .scaleEffect(dotScale(for: i))
                    .opacity(dotOpacity(for: i))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 18))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                phase = 1
            }
        }
    }

    private func dotScale(for index: Int) -> Double {
        let offset = Double(index) * 0.15
        let value = sin((phase + offset) * .pi)
        return 0.6 + 0.4 * value
    }

    private func dotOpacity(for index: Int) -> Double {
        let offset = Double(index) * 0.15
        let value = sin((phase + offset) * .pi)
        return 0.4 + 0.6 * value
    }
}
