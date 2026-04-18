import Foundation
import SwiftData

@Model
public final class Agent {
    @Attribute(.unique) public var agentId: String
    public var agentType: Int
    public var worktree: String
    public var branch: String
    public var status: Int
    public var startedAt: Date
    public var currentPrompt: String
    public var workspaceId: String
    public var sessionTitle: String
    public var lastEventSummary: String
    public var lastEventTime: Date?
    public var lastOutputSummary: String
    public var toolUseCount: Int
    public var hasUnread: Bool
    public var availableModelsJSON: String = ""
    public var currentModel: String?

    public init(agentId: String, agentType: Int = 1, worktree: String = "", branch: String = "",
                status: Int = 1, startedAt: Date = .now, currentPrompt: String = "",
                workspaceId: String = "") {
        self.agentId = agentId
        self.agentType = agentType
        self.worktree = worktree
        self.branch = branch
        self.status = status
        self.startedAt = startedAt
        self.currentPrompt = currentPrompt
        self.workspaceId = workspaceId
        self.sessionTitle = ""
        self.lastEventSummary = ""
        self.lastEventTime = nil
        self.lastOutputSummary = ""
        self.toolUseCount = 0
        self.hasUnread = false
    }

    public var isActive: Bool { status == 2 }
    public var isIdle: Bool { status == 3 }
    public var statusLabel: String {
        switch status {
        case 1: "Starting"
        case 2: "Active"
        case 3: "Idle"
        case 4: "Error"
        case 5: "Stopped"
        default: "Unknown"
        }
    }
    public var agentTypeLabel: String {
        switch agentType {
        case 1: "Claude Code"
        case 2: "OpenCode"
        case 3: "Codex"
        default: "Unknown"
        }
    }
}

public extension Agent {
    var availableModels: [AvailableModel] {
        guard !availableModelsJSON.isEmpty,
              let data = availableModelsJSON.data(using: .utf8),
              let models = try? JSONDecoder().decode([AvailableModel].self, from: data)
        else { return [] }
        return models
    }
}
