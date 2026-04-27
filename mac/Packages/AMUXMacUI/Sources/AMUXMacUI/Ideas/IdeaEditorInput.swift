import Foundation

/// Payload passed to `IdeaEditorWindow` via `openWindow(id:value:)`.
/// `ideaId == nil` means "create new idea".
public struct IdeaEditorInput: Codable, Hashable, Identifiable {
    public let ideaId: String?
    public let parentIdeaId: String?
    public let presetSessionId: String?
    public let presetWorkspaceId: String?

    public var id: String {
        ideaId ?? "new:\(parentIdeaId ?? "")"
    }

    public init(ideaId: String? = nil,
                parentIdeaId: String? = nil,
                presetSessionId: String? = nil,
                presetWorkspaceId: String? = nil) {
        self.ideaId = ideaId
        self.parentIdeaId = parentIdeaId
        self.presetSessionId = presetSessionId
        self.presetWorkspaceId = presetWorkspaceId
    }
}
