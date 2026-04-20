import Foundation

public enum SidebarFunction: String, CaseIterable, Hashable, Sendable {
    case sessions
    case tasks

    public var title: String {
        switch self {
        case .sessions: "Sessions"
        case .tasks: "Tasks"
        }
    }

    public var systemImage: String {
        switch self {
        case .sessions: "bubble.left.and.bubble.right"
        case .tasks: "checkmark.circle"
        }
    }
}

public enum SidebarItem: Hashable, Sendable {
    case function(SidebarFunction)
    case member(memberId: String)
    case workspace(workspaceId: String)
}
