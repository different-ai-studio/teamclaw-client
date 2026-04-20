import SwiftUI
import AMUXCore

struct TaskRow: View {
    let task: SessionTask
    let sessionTitle: String?
    let teamclawService: TeamclawService?

    @Environment(\.modelContext) private var modelContext

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            statusIcon
                .frame(width: 22, height: 22)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                Text(task.title.isEmpty ? "(untitled)" : task.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(2)

                HStack {
                    if let sessionTitle, !sessionTitle.isEmpty {
                        Text(sessionTitle)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else {
                        Text(task.statusLabel)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(timeLabel)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
        .padding(.vertical, 6)
        .contextMenu {
            Button {
                task.archived = true
                try? modelContext.save()
                let id = task.taskId
                let sessionId = task.sessionId
                Task { await teamclawService?.archiveTask(taskId: id, sessionId: sessionId, archived: true) }
            } label: {
                Label("Archive", systemImage: "archivebox")
            }
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch task.status {
        case "done":
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.title3)
        case "in_progress":
            Image(systemName: "circle.dotted")
                .foregroundStyle(.orange)
                .font(.title3)
        default:
            Image(systemName: "circle")
                .foregroundStyle(.secondary)
                .font(.title3)
        }
    }

    private var timeLabel: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: task.createdAt, relativeTo: .now)
    }
}
