import Foundation
import SwiftData

@Model
public final class SessionTask {
    @Attribute(.unique) public var taskId: String
    public var sessionId: String
    public var title: String
    public var taskDescription: String
    public var status: String           // "open", "in_progress", "done"
    public var parentTaskId: String
    public var createdBy: String
    public var createdAt: Date
    public var archived: Bool

    public init(
        taskId: String,
        sessionId: String = "",
        title: String = "",
        taskDescription: String = "",
        status: String = "open",
        parentTaskId: String = "",
        createdBy: String = "",
        createdAt: Date = .now,
        archived: Bool = false
    ) {
        self.taskId = taskId
        self.sessionId = sessionId
        self.title = title
        self.taskDescription = taskDescription
        self.status = status
        self.parentTaskId = parentTaskId
        self.createdBy = createdBy
        self.createdAt = createdAt
        self.archived = archived
    }

    public var displayTitle: String {
        if !title.isEmpty { return title }
        let desc = taskDescription
        if desc.count <= 50 { return desc }
        let prefix = desc.prefix(50)
        if let lastSpace = prefix.lastIndex(of: " ") {
            return String(prefix[prefix.startIndex..<lastSpace]) + "…"
        }
        return String(prefix) + "…"
    }

    public var isOpen: Bool { status == "open" }
    public var isInProgress: Bool { status == "in_progress" }
    public var isDone: Bool { status == "done" }
    public var statusLabel: String {
        switch status {
        case "open": return "Open"
        case "in_progress": return "In Progress"
        case "done": return "Done"
        default: return status
        }
    }
}
