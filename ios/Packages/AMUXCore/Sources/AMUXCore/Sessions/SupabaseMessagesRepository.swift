import Foundation
import Supabase

/// Snapshot of a Supabase `messages` row for the session-resume seed
/// path. Only the fields the iOS UI actually needs to render a past
/// turn (user prompt or finalized agent reply) are pulled — tool calls,
/// thinking deltas, and other intermediate ACP events are intentionally
/// not represented here.
public struct MessageRecord: Equatable, Sendable {
    public let id: String
    public let sessionID: String
    public let senderActorID: String
    public let kind: String
    public let content: String
    public let createdAt: Date
    /// Model id is currently stored inside `messages.metadata` JSON; not
    /// surfaced through the seed today. Left nil here until we add a typed
    /// metadata path.
    public let model: String?
}

/// Input shape for inserting a chat message into Supabase. iOS writes
/// human prompts here so collaborators on cold-launch get a complete
/// session history (the daemon only persists agent replies). RLS
/// `messages_insert_if_session_participant` gates on `sender_actor_id ==
/// app.current_actor_id()` and the caller's session-participant status.
public struct MessageInsertInput: Equatable, Sendable {
    public let id: String
    public let teamID: String
    public let sessionID: String
    public let senderActorID: String
    public let kind: String
    public let content: String

    public init(
        id: String = UUID().uuidString.lowercased(),
        teamID: String,
        sessionID: String,
        senderActorID: String,
        kind: String = "text",
        content: String
    ) {
        self.id = id
        self.teamID = teamID
        self.sessionID = sessionID
        self.senderActorID = senderActorID
        self.kind = kind
        self.content = content
    }
}

public protocol MessagesRepository: Sendable {
    func listForSession(sessionID: String) async throws -> [MessageRecord]
    func insert(_ input: MessageInsertInput) async throws
}

public actor SupabaseMessagesRepository: MessagesRepository {
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

    public func insert(_ input: MessageInsertInput) async throws {
        try await client
            .from("messages")
            .insert(
                MessageInsertRow(
                    id: input.id,
                    teamID: input.teamID,
                    sessionID: input.sessionID,
                    senderActorID: input.senderActorID,
                    kind: input.kind,
                    content: input.content
                ),
                returning: .minimal
            )
            .execute()
    }

    public func listForSession(sessionID: String) async throws -> [MessageRecord] {
        let rows: [MessageRow] = try await client
            .from("messages")
            .select("id, session_id, sender_actor_id, kind, content, created_at")
            .eq("session_id", value: sessionID)
            .order("created_at", ascending: true)
            .execute()
            .value

        return rows.map { row in
            MessageRecord(
                id: row.id,
                sessionID: row.sessionID,
                senderActorID: row.senderActorID,
                kind: row.kind,
                content: row.content,
                createdAt: row.createdAt,
                model: nil
            )
        }
    }
}

private struct MessageInsertRow: Encodable, Sendable {
    let id: String
    let teamID: String
    let sessionID: String
    let senderActorID: String
    let kind: String
    let content: String

    enum CodingKeys: String, CodingKey {
        case id
        case teamID = "team_id"
        case sessionID = "session_id"
        case senderActorID = "sender_actor_id"
        case kind
        case content
    }
}

private struct MessageRow: Decodable, Sendable {
    let id: String
    let sessionID: String
    let senderActorID: String
    let kind: String
    let content: String
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case sessionID = "session_id"
        case senderActorID = "sender_actor_id"
        case kind
        case content
        case createdAt = "created_at"
    }
}
