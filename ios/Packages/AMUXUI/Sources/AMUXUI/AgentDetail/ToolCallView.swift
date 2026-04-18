import SwiftUI
import AMUXCore

// MARK: - ToolCallView

public struct ToolCallView: View {
    let toolName: String
    let toolId: String
    let description: String
    let status: String
    @State private var isExpanded = false

    private var hasDetails: Bool {
        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed != "{}" && trimmed != "null"
    }

    public init(toolName: String, toolId: String, description: String, status: String) {
        self.toolName = toolName
        self.toolId = toolId
        self.description = description
        self.status = status
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                if hasDetails { withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() } }
            } label: {
                HStack(spacing: 6) {
                    if hasDetails {
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .foregroundStyle(.secondary)
                    }

                    Image(systemName: toolIcon)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text(displayName)
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if hasDetails && !isExpanded {
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

            if isExpanded && hasDetails {
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

// MARK: - CompactToolLine

public struct CompactToolLine: View {
    let event: AgentEvent
    @State private var showDetail = false

    private var toolName: String { event.toolName ?? "" }
    private var description: String { event.text ?? "" }
    private var succeeded: Bool { event.success != false }

    private var hasDetails: Bool {
        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed != "{}" && trimmed != "null"
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: succeeded ? "checkmark" : "xmark")
                    .font(.system(size: 9))
                    .foregroundStyle(succeeded ? .green : .red)

                Image(systemName: ToolCallView.icon(for: toolName))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)

                Text(ToolCallView.shortName(for: toolName.isEmpty ? (event.toolId ?? "") : toolName))
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 1)
            .contentShape(Rectangle())
            .onTapGesture {
                if hasDetails {
                    withAnimation(.easeInOut(duration: 0.15)) { showDetail.toggle() }
                }
            }

            if showDetail && hasDetails {
                Text(description)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 4)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

// MARK: - ToolRunSummaryBar

public struct ToolRunSummaryBar: View {
    let events: [AgentEvent]
    @State private var isExpanded = false

    private var count: Int { events.count }

    private var hasFailure: Bool {
        events.contains { $0.success == false }
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

                    Image(systemName: "wrench")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text("\(count) tools completed")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(.primary)

                    Spacer()

                    if hasFailure {
                        Image(systemName: "exclamationmark.triangle.fill")
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

            if isExpanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(events, id: \.id) { event in
                        CompactToolLine(event: event)
                    }
                }
                .padding(.bottom, 4)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Event Grouping

public enum GroupedEvent: Identifiable {
    case single(AgentEvent)
    case toolRun(id: String, events: [AgentEvent])

    public var id: String {
        switch self {
        case .single(let e): e.id
        case .toolRun(let id, _): id
        }
    }
}

/// Groups completed tool_use events into tool runs, skipping over
/// thinking and tool_result events that naturally occur between tools.
/// A tool run breaks at user_prompt, output, error, permission_request, or todo_update.
/// Running/incomplete tools also break the run.
public func groupEvents(_ events: [AgentEvent]) -> [GroupedEvent] {
    // Events that can appear between tool calls without breaking the run
    let skippableTypes: Set<String> = ["thinking", "tool_result"]

    var result: [GroupedEvent] = []
    var i = 0
    while i < events.count {
        let event = events[i]

        if event.eventType == "tool_use", event.isComplete {
            // Start collecting a tool run
            var toolEvents: [AgentEvent] = [event]
            var skippedEvents: [AgentEvent] = []
            var j = i + 1

            while j < events.count {
                let next = events[j]
                if next.eventType == "tool_use", next.isComplete {
                    // Another completed tool — absorb any skipped events and continue
                    skippedEvents.removeAll()
                    toolEvents.append(next)
                    j += 1
                } else if skippableTypes.contains(next.eventType) {
                    // Thinking/tool_result between tools — tentatively skip
                    skippedEvents.append(next)
                    j += 1
                } else {
                    // Content event — stop the run
                    break
                }
            }

            if toolEvents.count >= 3 {
                let groupId = "toolrun-\(toolEvents.first!.id)"
                result.append(.toolRun(id: groupId, events: toolEvents))
            } else {
                for e in toolEvents { result.append(.single(e)) }
            }
            // Put back any trailing skipped events that weren't followed by a tool
            for e in skippedEvents { result.append(.single(e)) }
            i = j
        } else {
            result.append(.single(event))
            i += 1
        }
    }
    return result
}
