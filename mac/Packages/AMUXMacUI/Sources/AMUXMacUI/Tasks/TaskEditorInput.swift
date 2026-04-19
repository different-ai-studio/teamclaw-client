import Foundation

/// Payload passed to `TaskEditorWindow` via `openWindow(id:value:)`.
/// `workItemId == nil` means "create new task".
public struct TaskEditorInput: Codable, Hashable, Identifiable {
    public let workItemId: String?
    public let parentTaskId: String?
    public let presetSessionId: String?

    public var id: String {
        workItemId ?? "new:\(parentTaskId ?? "")"
    }

    public init(workItemId: String? = nil,
                parentTaskId: String? = nil,
                presetSessionId: String? = nil) {
        self.workItemId = workItemId
        self.parentTaskId = parentTaskId
        self.presetSessionId = presetSessionId
    }
}
