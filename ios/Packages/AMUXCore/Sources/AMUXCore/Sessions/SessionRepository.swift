import Foundation
import Supabase

public struct SessionParticipantInput: Equatable, Sendable {
    public let actorID: String
    public let role: String?

    public init(actorID: String, role: String? = nil) {
        self.actorID = actorID
        self.role = role
    }
}

public struct SessionCreateInput: Equatable, Sendable {
    public let id: String
    public let teamID: String
    public let taskID: String?
    public let createdByActorID: String
    public let primaryAgentID: String?
    public let mode: String
    public let title: String
    public let summary: String
    public let hostDeviceID: String
    public let participants: [SessionParticipantInput]

    public init(
        id: String,
        teamID: String,
        taskID: String? = nil,
        createdByActorID: String,
        primaryAgentID: String? = nil,
        mode: String = "collab",
        title: String,
        summary: String,
        hostDeviceID: String,
        participants: [SessionParticipantInput]
    ) {
        self.id = id
        self.teamID = teamID
        self.taskID = taskID
        self.createdByActorID = createdByActorID
        self.primaryAgentID = primaryAgentID
        self.mode = mode
        self.title = title
        self.summary = summary
        self.hostDeviceID = hostDeviceID
        self.participants = participants
    }
}

public protocol SessionRepository: Sendable {
    func createSession(_ input: SessionCreateInput) async throws
}

public enum SessionRepositoryError: LocalizedError {
    case missingTitle
    case missingParticipants

    public var errorDescription: String? {
        switch self {
        case .missingTitle:
            return "Session title is required."
        case .missingParticipants:
            return "Session participants are required."
        }
    }
}

public actor SupabaseSessionRepository: SessionRepository {
    private let client: SupabaseClient

    public init(configuration: SupabaseProjectConfiguration) {
        self.client = SupabaseClient(
            supabaseURL: configuration.url,
            supabaseKey: configuration.publishableKey
        )
    }

    public init() throws {
        let configuration = try SupabaseProjectConfiguration.fromMainBundle()
        self.client = SupabaseClient(
            supabaseURL: configuration.url,
            supabaseKey: configuration.publishableKey
        )
    }

    public func createSession(_ input: SessionCreateInput) async throws {
        let title = input.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            throw SessionRepositoryError.missingTitle
        }
        guard !input.participants.isEmpty else {
            throw SessionRepositoryError.missingParticipants
        }

        try await client
            .from("sessions")
            .insert(
                SessionInsertRow(
                    id: input.id,
                    teamID: input.teamID,
                    taskID: normalized(input.taskID),
                    createdByActorID: input.createdByActorID,
                    primaryAgentID: normalized(input.primaryAgentID),
                    mode: input.mode,
                    title: title,
                    summary: input.summary
                ),
                returning: .minimal
            )
            .execute()

        try await client
            .from("session_participants")
            .insert(
                input.participants.map { participant in
                    SessionParticipantInsertRow(
                        id: UUID().uuidString.lowercased(),
                        sessionID: input.id,
                        actorID: participant.actorID,
                        role: participant.role
                    )
                },
                returning: .minimal
            )
            .execute()
    }

    private func normalized(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

private struct SessionInsertRow: Encodable, Sendable {
    let id: String
    let teamID: String
    let taskID: String?
    let createdByActorID: String
    let primaryAgentID: String?
    let mode: String
    let title: String
    let summary: String

    enum CodingKeys: String, CodingKey {
        case id
        case teamID = "team_id"
        case taskID = "task_id"
        case createdByActorID = "created_by_actor_id"
        case primaryAgentID = "primary_agent_id"
        case mode
        case title
        case summary
    }
}

private struct SessionParticipantInsertRow: Encodable, Sendable {
    let id: String
    let sessionID: String
    let actorID: String
    let role: String?

    enum CodingKeys: String, CodingKey {
        case id
        case sessionID = "session_id"
        case actorID = "actor_id"
        case role
    }
}
