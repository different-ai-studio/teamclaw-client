import Foundation
import SwiftData

@Model
public final class Session {
    @Attribute(.unique) public var sessionId: String
    public var teamId: String
    public var title: String
    public var createdBy: String
    public var createdAt: Date
    public var summary: String
    public var participantCount: Int
    public var lastMessagePreview: String
    public var lastMessageAt: Date?
    public var ideaId: String
    public var primaryAgentId: String?

    public init(
        sessionId: String,
        teamId: String = "",
        title: String = "",
        createdBy: String = "",
        createdAt: Date = .now,
        summary: String = "",
        participantCount: Int = 0,
        lastMessagePreview: String = "",
        lastMessageAt: Date? = nil,
        ideaId: String = ""
    ) {
        self.sessionId = sessionId
        self.teamId = teamId
        self.title = title
        self.createdBy = createdBy
        self.createdAt = createdAt
        self.summary = summary
        self.participantCount = participantCount
        self.lastMessagePreview = lastMessagePreview
        self.lastMessageAt = lastMessageAt
        self.ideaId = ideaId
    }
}
