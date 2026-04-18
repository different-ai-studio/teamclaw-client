import SwiftUI

/// Renders a todo_update event payload as a checklist. The daemon emits one
/// line per todo, prefixed with `[done]`, `[wip]`, or `[todo]`; anything else
/// falls back to an unchecked circle. Matches the iOS AMUXUI.TodoListView.
struct TodoListView: View {
    let text: String

    private var items: [(icon: String, label: String)] {
        text.split(separator: "\n").map { line in
            let s = String(line)
            if s.hasPrefix("[done]") {
                return ("checkmark.circle.fill", String(s.dropFirst(6)).trimmingCharacters(in: .whitespaces))
            } else if s.hasPrefix("[wip]") {
                return ("arrow.triangle.2.circlepath", String(s.dropFirst(5)).trimmingCharacters(in: .whitespaces))
            } else if s.hasPrefix("[todo]") {
                return ("circle", String(s.dropFirst(6)).trimmingCharacters(in: .whitespaces))
            }
            return ("circle", s)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "checklist").font(.caption).foregroundStyle(.secondary)
                Text("Tasks").font(.caption).fontWeight(.medium).foregroundStyle(.secondary)
            }
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(spacing: 8) {
                    Image(systemName: item.icon)
                        .font(.caption)
                        .foregroundStyle(color(for: item.icon))
                    Text(item.label)
                        .font(.subheadline)
                        .strikethrough(item.icon == "checkmark.circle.fill")
                        .foregroundStyle(item.icon == "checkmark.circle.fill" ? .secondary : .primary)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
    }

    private func color(for icon: String) -> Color {
        switch icon {
        case "checkmark.circle.fill": .green
        case "arrow.triangle.2.circlepath": .orange
        default: .secondary
        }
    }
}
