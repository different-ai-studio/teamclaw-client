import SwiftUI

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
                        .foregroundStyle(.primary)

                    Image(systemName: toolIcon)
                        .font(.caption)
                        .foregroundStyle(.primary)

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
        .liquidGlass(in: RoundedRectangle(cornerRadius: 8), interactive: false)
    }

    private var toolIcon: String {
        let n = toolName.lowercased()
        if n.contains("write") || n.contains("edit") { return "doc.text" }
        if n.contains("read") { return "doc" }
        if n.contains("bash") || n.contains("shell") || n.contains("terminal") { return "terminal" }
        if n.contains("search") || n.contains("grep") || n.contains("glob") { return "magnifyingglass" }
        if n.contains("task") { return "person.2" }
        if n.contains("web") { return "globe" }
        return "wrench"
    }

    private var displayName: String {
        let name = toolName.isEmpty ? toolId : toolName
        // Extract last segment after "__" (e.g. mcp__plugin__tool_name → tool_name)
        if let range = name.range(of: "__", options: .backwards) {
            let short = String(name[range.upperBound...])
            return String(short.prefix(30))
        }
        return String(name.prefix(30))
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
}
