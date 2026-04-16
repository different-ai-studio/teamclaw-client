import SwiftUI

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
                Image(systemName: "checklist").font(.caption).foregroundStyle(.primary)
                Text("Tasks").font(.caption).fontWeight(.medium).foregroundStyle(.secondary)
            }
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(spacing: 8) {
                    Image(systemName: item.icon)
                        .font(.caption)
                        .foregroundStyle(.primary)
                    Text(item.label)
                        .font(.subheadline)
                        .strikethrough(item.icon == "checkmark.circle.fill")
                        .foregroundStyle(item.icon == "checkmark.circle.fill" ? .secondary : .primary)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlass(in: RoundedRectangle(cornerRadius: 12), interactive: false)
    }
}
