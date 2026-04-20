import Foundation

/// Payload passed to `TaskEditorWindow` via `openWindow(id:value:)`.
/// `taskId == nil` means "create new task".
public struct TaskEditorInput: Codable, Hashable, Identifiable {
    public let taskId: String?
    public let parentTaskId: String?
    public let presetSessionId: String?
    public let presetWorkspaceId: String?

    public var id: String {
        taskId ?? "new:\(parentTaskId ?? "")"
    }

    public init(taskId: String? = nil,
                parentTaskId: String? = nil,
                presetSessionId: String? = nil,
                presetWorkspaceId: String? = nil) {
        self.taskId = taskId
        self.parentTaskId = parentTaskId
        self.presetSessionId = presetSessionId
        self.presetWorkspaceId = presetWorkspaceId
    }
}
