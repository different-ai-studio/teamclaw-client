import Foundation
import SwiftData

/// Canonical SwiftData schema for the app. Declaring this as a `VersionedSchema`
/// and passing it through a `SchemaMigrationPlan` stops SwiftData from falling
/// back to destructive migration when model shapes change.
///
/// Whenever you change the shape of ANY `@Model` class in this module:
/// 1. Snapshot the previous model shape into `AMUXSchemaV<N>`.
/// 2. Introduce a new schema version that points at the live models.
/// 3. Register a migration stage for the transition.
public enum AMUXSchemaV1: VersionedSchema {
    public static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }

    public static var models: [any PersistentModel.Type] {
        [
            Agent.self,
            AgentEvent.self,
            Member.self,
            Workspace.self,
            Session.self,
            SessionMessage.self,
            SessionTask.self,
        ]
    }

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
        public var availableModelsJSON: String
        public var currentModel: String?

        public init(
            agentId: String,
            agentType: Int = 1,
            worktree: String = "",
            branch: String = "",
            status: Int = 1,
            startedAt: Date = .now,
            currentPrompt: String = "",
            workspaceId: String = "",
            sessionTitle: String = "",
            lastEventSummary: String = "",
            lastEventTime: Date? = nil,
            lastOutputSummary: String = "",
            toolUseCount: Int = 0,
            hasUnread: Bool = false,
            availableModelsJSON: String = "",
            currentModel: String? = nil
        ) {
            self.agentId = agentId
            self.agentType = agentType
            self.worktree = worktree
            self.branch = branch
            self.status = status
            self.startedAt = startedAt
            self.currentPrompt = currentPrompt
            self.workspaceId = workspaceId
            self.sessionTitle = sessionTitle
            self.lastEventSummary = lastEventSummary
            self.lastEventTime = lastEventTime
            self.lastOutputSummary = lastOutputSummary
            self.toolUseCount = toolUseCount
            self.hasUnread = hasUnread
            self.availableModelsJSON = availableModelsJSON
            self.currentModel = currentModel
        }
    }

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
        public var model: String?

        public init(
            id: String = UUID().uuidString,
            agentId: String,
            sequence: Int,
            timestamp: Date = .now,
            eventType: String,
            text: String? = nil,
            toolName: String? = nil,
            toolId: String? = nil,
            isComplete: Bool = false,
            success: Bool? = nil,
            model: String? = nil
        ) {
            self.id = id
            self.agentId = agentId
            self.sequence = sequence
            self.timestamp = timestamp
            self.eventType = eventType
            self.text = text
            self.toolName = toolName
            self.toolId = toolId
            self.isComplete = isComplete
            self.success = success
            self.model = model
        }
    }

    @Model
    public final class Member {
        @Attribute(.unique) public var memberId: String
        public var displayName: String
        public var role: Int
        public var joinedAt: Date
        public var department: String?

        public init(
            memberId: String,
            displayName: String,
            role: Int = 1,
            joinedAt: Date = .now,
            department: String? = nil
        ) {
            self.memberId = memberId
            self.displayName = displayName
            self.role = role
            self.joinedAt = joinedAt
            self.department = department
        }
    }

    @Model
    public final class Workspace {
        @Attribute(.unique) public var workspaceId: String
        public var path: String
        public var displayName: String

        public init(workspaceId: String, path: String, displayName: String) {
            self.workspaceId = workspaceId
            self.path = path
            self.displayName = displayName
        }
    }

    @Model
    public final class Session {
        @Attribute(.unique) public var sessionId: String
        public var mode: String
        public var teamId: String
        public var title: String
        public var hostDeviceId: String
        public var createdBy: String
        public var createdAt: Date
        public var summary: String
        public var participantCount: Int
        public var lastMessagePreview: String
        public var lastMessageAt: Date?
        public var taskId: String
        public var primaryAgentId: String?

        public init(
            sessionId: String,
            mode: String = "collab",
            teamId: String = "",
            title: String = "",
            hostDeviceId: String = "",
            createdBy: String = "",
            createdAt: Date = .now,
            summary: String = "",
            participantCount: Int = 0,
            lastMessagePreview: String = "",
            lastMessageAt: Date? = nil,
            taskId: String = "",
            primaryAgentId: String? = nil
        ) {
            self.sessionId = sessionId
            self.mode = mode
            self.teamId = teamId
            self.title = title
            self.hostDeviceId = hostDeviceId
            self.createdBy = createdBy
            self.createdAt = createdAt
            self.summary = summary
            self.participantCount = participantCount
            self.lastMessagePreview = lastMessagePreview
            self.lastMessageAt = lastMessageAt
            self.taskId = taskId
            self.primaryAgentId = primaryAgentId
        }
    }

    @Model
    public final class SessionMessage {
        @Attribute(.unique) public var messageId: String
        public var sessionId: String
        public var senderActorId: String
        public var kind: String
        public var content: String
        public var createdAt: Date
        public var replyToMessageId: String
        public var mentions: String
        public var model: String?

        public init(
            messageId: String,
            sessionId: String = "",
            senderActorId: String = "",
            kind: String = "text",
            content: String = "",
            createdAt: Date = .now,
            replyToMessageId: String = "",
            mentions: String = "",
            model: String? = nil
        ) {
            self.messageId = messageId
            self.sessionId = sessionId
            self.senderActorId = senderActorId
            self.kind = kind
            self.content = content
            self.createdAt = createdAt
            self.replyToMessageId = replyToMessageId
            self.mentions = mentions
            self.model = model
        }
    }

    @Model
    public final class SessionTask {
        @Attribute(.unique) public var taskId: String
        public var sessionId: String
        public var title: String
        public var taskDescription: String
        public var status: String
        public var parentTaskId: String
        public var createdBy: String
        public var createdAt: Date
        public var archived: Bool

        public init(
            taskId: String,
            sessionId: String = "",
            title: String = "",
            taskDescription: String = "",
            status: String = "open",
            parentTaskId: String = "",
            createdBy: String = "",
            createdAt: Date = .now,
            archived: Bool = false
        ) {
            self.taskId = taskId
            self.sessionId = sessionId
            self.title = title
            self.taskDescription = taskDescription
            self.status = status
            self.parentTaskId = parentTaskId
            self.createdBy = createdBy
            self.createdAt = createdAt
            self.archived = archived
        }
    }
}

public enum AMUXSchemaV2: VersionedSchema {
    public static var versionIdentifier: Schema.Version { Schema.Version(2, 0, 0) }

    public static var models: [any PersistentModel.Type] {
        [
            Agent.self,
            AgentEvent.self,
            Member.self,
            Workspace.self,
            Session.self,
            SessionMessage.self,
            SessionTask.self,
        ]
    }
}

public enum AMUXMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] {
        [AMUXSchemaV1.self, AMUXSchemaV2.self]
    }

    public static var stages: [MigrationStage] {
        [
            .lightweight(fromVersion: AMUXSchemaV1.self, toVersion: AMUXSchemaV2.self),
        ]
    }
}
