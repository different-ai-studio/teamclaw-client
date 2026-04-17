import Foundation
import SwiftData

@Model
public final class CollabSession {
    @Attribute(.unique) public var sessionId: String
    public var sessionType: String       // "control" or "collab"
    public var teamId: String
    public var title: String
    public var hostDeviceId: String
    public var createdBy: String
    public var createdAt: Date
    public var summary: String
    public var participantCount: Int
    public var lastMessagePreview: String
    public var lastMessageAt: Date?
    public var workItemId: String

    public init(
        sessionId: String,
        sessionType: String = "collab",
        teamId: String = "",
        title: String = "",
        hostDeviceId: String = "",
        createdBy: String = "",
        createdAt: Date = .now,
        summary: String = "",
        participantCount: Int = 0,
        lastMessagePreview: String = "",
        lastMessageAt: Date? = nil,
        workItemId: String = ""
    ) {
        self.sessionId = sessionId
        self.sessionType = sessionType
        self.teamId = teamId
        self.title = title
        self.hostDeviceId = hostDeviceId
        self.createdBy = createdBy
        self.createdAt = createdAt
        self.summary = summary
        self.participantCount = participantCount
        self.lastMessagePreview = lastMessagePreview
        self.lastMessageAt = lastMessageAt
        self.workItemId = workItemId
    }

    public var isCollab: Bool { sessionType == "collab" }
    public var isControl: Bool { sessionType == "control" }
}
