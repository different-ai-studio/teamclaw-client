import Foundation
import SwiftData

/// Snapshot of a Supabase `agent_runtimes` row, cached locally so the iOS
/// session list can display the real backend type and workspace even when the
/// daemon's MQTT-published `Runtime` row is offline.
///
/// Multiple runtimes can share the same `sessionId` over a session's lifetime
/// (stop → respawn, status transitions). Lookup by session picks the most
/// recently updated row.
@Model
public final class CachedAgentRuntime {
    @Attribute(.unique) public var id: String
    public var teamId: String
    public var agentId: String
    public var sessionId: String?
    public var workspaceId: String?
    /// "claude" | "codex" | "opencode"
    public var backendType: String
    /// "starting" | "running" | "idle" | "stopped" | "failed"
    public var status: String
    /// Bridge to the MQTT-published `Runtime.runtimeId` (8-char). When the
    /// daemon is online and publishing, the matching live Runtime can be
    /// looked up by this value.
    public var backendSessionId: String?
    public var currentModel: String?
    public var lastSeenAt: Date?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String,
        teamId: String,
        agentId: String,
        sessionId: String? = nil,
        workspaceId: String? = nil,
        backendType: String,
        status: String,
        backendSessionId: String? = nil,
        currentModel: String? = nil,
        lastSeenAt: Date? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.teamId = teamId
        self.agentId = agentId
        self.sessionId = sessionId
        self.workspaceId = workspaceId
        self.backendType = backendType
        self.status = status
        self.backendSessionId = backendSessionId
        self.currentModel = currentModel
        self.lastSeenAt = lastSeenAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
