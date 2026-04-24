import Foundation
import SwiftData

@Model
public final class AgentEvent {
    @Attribute(.unique) public var id: String
    public var agentId: String
    public var sequence: Int
    public var timestamp: Date
    public var eventType: String
    public var text: String?
    public var toolName: String?
    public var toolId: String?
    public var isComplete: Bool
    public var success: Bool?
    /// Model id that produced this event (set by the daemon on agent-reply
    /// events: output and thinking). nil for user prompts, tool events,
    /// status changes, errors, permission requests.
    public var model: String?

    public init(agentId: String, sequence: Int, eventType: String) {
        self.id = UUID().uuidString
        self.agentId = agentId
        self.sequence = sequence
        self.timestamp = .now
        self.eventType = eventType
        self.isComplete = false
    }
}

public extension AgentEvent {
    /// Returns the human display name for `model` resolved against the runtime's
    /// available models, or nil if no model is stamped. Falls back to the raw
    /// model id when no display name is registered (e.g. proto-only model id
    /// from a future daemon).
    func modelDisplayName(via runtime: Runtime) -> String? {
        guard let modelId = self.model, !modelId.isEmpty else { return nil }
        return runtime.availableModels.first(where: { $0.id == modelId })?.displayName ?? modelId
    }
}
