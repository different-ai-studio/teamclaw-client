import Foundation
import SwiftData

@Model
public final class WorkItem {
    @Attribute(.unique) public var workItemId: String
    public var sessionId: String
    public var title: String
    public var itemDescription: String  // "description" is reserved in some contexts
    public var status: String           // "open", "in_progress", "done"
    public var parentId: String
    public var createdBy: String
    public var createdAt: Date

    public init(
        workItemId: String,
        sessionId: String = "",
        title: String = "",
        itemDescription: String = "",
        status: String = "open",
        parentId: String = "",
        createdBy: String = "",
        createdAt: Date = .now
    ) {
        self.workItemId = workItemId
        self.sessionId = sessionId
        self.title = title
        self.itemDescription = itemDescription
        self.status = status
        self.parentId = parentId
        self.createdBy = createdBy
        self.createdAt = createdAt
    }

    public var displayTitle: String {
        if !title.isEmpty { return title }
        let desc = itemDescription
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
