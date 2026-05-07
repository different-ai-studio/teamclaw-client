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
    /// Supabase `messages.id` when this event was seeded from the
    /// `messages` table on session resume. Used as the dedupe key so a
    /// later cold-resume of the same session doesn't insert a second copy.
    /// nil for events created from MQTT live deltas / daemon history.
    public var supabaseMessageId: String?
    /// Actor id of the user/agent who produced this event. Set by every
    /// insert path (local sendPrompt, live MQTT message, Supabase seed,
    /// daemon ACP fanout) so the chat feed can render real sender names
    /// instead of always saying "You". `nil` only for legacy rows
    /// inserted before this column existed.
    public var senderActorID: String?

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
