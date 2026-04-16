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

    public init(agentId: String, sequence: Int, eventType: String) {
        self.id = UUID().uuidString
        self.agentId = agentId
        self.sequence = sequence
        self.timestamp = .now
        self.eventType = eventType
        self.isComplete = false
    }
}
