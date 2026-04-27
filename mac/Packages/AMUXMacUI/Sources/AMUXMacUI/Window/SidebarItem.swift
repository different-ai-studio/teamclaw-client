import Foundation

public enum SidebarFunction: String, CaseIterable, Hashable, Sendable {
    case sessions
    case ideas

    public var title: String {
        switch self {
        case .sessions: "Sessions"
        case .ideas: "Ideas"
        }
    }

    public var systemImage: String {
        switch self {
        case .sessions: "bubble.left.and.bubble.right"
        case .ideas: "lightbulb"
        }
    }
}

public enum SidebarItem: Hashable, Sendable {
    case function(SidebarFunction)
    case member(memberId: String)
    case workspace(workspaceId: String)
}
