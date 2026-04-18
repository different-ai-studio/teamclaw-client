import SwiftUI
import AMUXCore

/// macOS renderer for a single AgentEvent. Mirrors iOS EventBubbleView's
/// dispatch on `eventType` but uses macOS-compatible APIs (NSPasteboard,
/// NSWorkspace, AppKit-friendly colors). Kept minimal - covers the core
/// event types streamed by the daemon (user_prompt, output, thinking,
/// tool_use, error, permission_request, todo_update).
struct AgentEventRow: View {
    let event: AgentEvent
    let agent: Agent?
    let onGrant: ((String) -> Void)?
    let onDeny: ((String) -> Void)?

    init(event: AgentEvent,
         agent: Agent? = nil,
         onGrant: ((String) -> Void)? = nil,
         onDeny: ((String) -> Void)? = nil) {
        self.event = event
        self.agent = agent
        self.onGrant = onGrant
        self.onDeny = onDeny
    }

    private var modelDisplayName: String? {
        guard let agent else { return nil }
        return event.modelDisplayName(via: agent)
    }

    var body: some View {
        switch event.eventType {
        case "user_prompt":    userBubble
        case "output":         assistantBubble
        case "thinking":       thinkingBlock
        case "tool_use":       toolUseBlock
        case "tool_result":    EmptyView()
        case "error":          errorBlock
        case "permission_request": permissionBlock
        case "todo_update":    todoBlock
        default:               EmptyView()
        }
    }

    // MARK: - User bubble (right-aligned, blue)

    private var userBubble: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text("You")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Text(event.text ?? "")
                    .font(.subheadline)
                    .foregroundStyle(.white)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.blue)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .frame(maxWidth: 500, alignment: .trailing)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }

    // MARK: - Assistant bubble (left-aligned, gray)

    private var assistantBubble: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(event.text ?? "")
                .font(.subheadline)
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 16))
            if event.isComplete, let modelName = modelDisplayName {
                Text(modelName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 6)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }

    // MARK: - Thinking (dim, collapsible)

    private var thinkingBlock: some View {
        AgentEventThinkingView(text: event.text ?? "")
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
    }

    // MARK: - Tool use

    private var toolUseBlock: some View {
        HStack(spacing: 8) {
            Image(systemName: event.isComplete == true
                  ? (event.success == false ? "xmark.circle" : "checkmark.circle")
                  : "hammer")
                .foregroundStyle(event.isComplete == true
                                 ? (event.success == false ? Color.red : Color.green)
                                 : Color.secondary)
                .font(.caption)
            Text(event.toolName ?? "Tool")
                .font(.caption)
                .fontWeight(.medium)
            if let desc = event.text, !desc.isEmpty {
                Text(desc)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer()
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 3)
    }

    // MARK: - Error

    private var errorBlock: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(event.text ?? "Unknown error")
                .font(.caption)
                .foregroundStyle(.red)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }

    // MARK: - Permission banner (grant/deny)

    private var permissionBlock: some View {
        let resolved = event.isComplete == true
        let granted = event.success
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "lock.shield")
                    .foregroundStyle(.orange)
                Text("Permission requested: \(event.toolName ?? "")")
                    .font(.caption)
                    .fontWeight(.medium)
            }
            if let desc = event.text, !desc.isEmpty {
                Text(desc)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if resolved {
                Text(granted == true ? "Granted" : "Denied")
                    .font(.caption)
                    .foregroundStyle(granted == true ? .green : .red)
            } else {
                HStack(spacing: 8) {
                    Button("Deny")   { onDeny?(event.toolId ?? "") }
                        .controlSize(.small)
                    Button("Allow")  { onGrant?(event.toolId ?? "") }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                    Spacer()
                }
            }
        }
        .padding(12)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }

    // MARK: - Todo list

    private var todoBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label("Todos", systemImage: "checklist")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(event.text ?? "")
                .font(.caption)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }
}

private struct AgentEventThinkingView: View {
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
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}
