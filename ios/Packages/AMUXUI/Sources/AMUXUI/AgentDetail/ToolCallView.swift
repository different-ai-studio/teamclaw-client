import SwiftUI
import AMUXCore

// MARK: - ToolCallView

public struct ToolCallView: View {
    let toolName: String
    let toolId: String
    let description: String
    let status: String
    @State private var isExpanded = false

    public init(toolName: String, toolId: String, description: String, status: String) {
        self.toolName = toolName
        self.toolId = toolId
        self.description = description
        self.status = status
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .foregroundStyle(.secondary)

                    Image(systemName: toolIcon)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text(displayName)
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if !description.isEmpty && !isExpanded {
                        Text(description)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer()

                    statusIndicator
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .buttonStyle(.plain)

            if isExpanded && !description.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Details")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(description)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.primary)
                        .lineLimit(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                        .background(Color(.systemBackground).opacity(0.6))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var toolIcon: String {
        Self.icon(for: toolName)
    }

    private var displayName: String {
        Self.shortName(for: toolName.isEmpty ? toolId : toolName)
    }

    @ViewBuilder
    private var statusIndicator: some View {
        switch status {
        case "running":
            ProgressView()
                .scaleEffect(0.6)
                .frame(width: 14, height: 14)
        case "completed":
            Image(systemName: "checkmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(.green)
        case "failed":
            Image(systemName: "xmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(.red)
        default:
            EmptyView()
        }
    }

    // MARK: - Shared helpers

    static func icon(for name: String) -> String {
        let n = name.lowercased()
        if n.contains("write") || n.contains("edit") { return "doc.text" }
        if n.contains("read") { return "doc" }
        if n.contains("bash") || n.contains("shell") || n.contains("terminal") { return "terminal" }
        if n.contains("search") || n.contains("grep") || n.contains("glob") { return "magnifyingglass" }
        if n.contains("task") { return "person.2" }
        if n.contains("web") { return "globe" }
        return "wrench"
    }

    static func shortName(for name: String) -> String {
        if let range = name.range(of: "__", options: .backwards) {
            return String(name[range.upperBound...].prefix(30))
        }
        return String(name.prefix(30))
    }
}

// MARK: - MergedToolCallView

/// Shows a group of consecutive completed tool calls of the same type as a single collapsed row.
/// Expanding reveals each individual call.
public struct MergedToolCallView: View {
    let toolName: String
    let events: [AgentEvent]
    @State private var isExpanded = false

    private var count: Int { events.count }

    private var hasFailure: Bool {
        events.contains { $0.success == false }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header row
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .foregroundStyle(.secondary)

                    Image(systemName: ToolCallView.icon(for: toolName))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text(ToolCallView.shortName(for: toolName))
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Text("\u{00D7}\(count)")
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)

                    Spacer()

                    if hasFailure {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.green)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .buttonStyle(.plain)

            // Expanded: show each call
            if isExpanded {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(events, id: \.id) { event in
                        MergedToolDetailRow(event: event)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 6)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

/// A compact row inside a merged tool group showing one call's description.
private struct MergedToolDetailRow: View {
    let event: AgentEvent
    @State private var showDetail = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { showDetail.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: event.success == true ? "checkmark" : "xmark")
                        .font(.system(size: 8))
                        .foregroundStyle(event.success == true ? .green : .red)

                    Text(event.text ?? "")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.primary)
                        .lineLimit(showDetail ? 10 : 1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
            }
            .buttonStyle(.plain)
        }
        .background(showDetail ? Color(.systemBackground).opacity(0.5) : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

// MARK: - Event Grouping

/// Represents either a single event or a merged group of tool calls.
public enum GroupedEvent: Identifiable {
    case single(AgentEvent)
    case mergedTools(id: String, toolName: String, events: [AgentEvent])

    public var id: String {
        switch self {
        case .single(let e): e.id
        case .mergedTools(let id, _, _): id
        }
    }
}

/// Groups consecutive completed tool_use events of the same tool name.
/// Running tools and non-tool events are never merged.
public func groupEvents(_ events: [AgentEvent]) -> [GroupedEvent] {
    var result: [GroupedEvent] = []
    var i = 0
    while i < events.count {
        let event = events[i]

        // Only merge completed tool_use events
        if event.eventType == "tool_use", event.isComplete,
           let toolName = event.toolName {
            // Collect consecutive completed tool_use with same toolName
            var group = [event]
            var j = i + 1
            while j < events.count,
                  events[j].eventType == "tool_use",
                  events[j].isComplete,
                  events[j].toolName == toolName {
                group.append(events[j])
                j += 1
            }

            if group.count >= 2 {
                let groupId = "merged-\(group.first!.id)"
                result.append(.mergedTools(id: groupId, toolName: toolName, events: group))
            } else {
                result.append(.single(event))
            }
            i = j
        } else {
            result.append(.single(event))
            i += 1
        }
    }
    return result
}
