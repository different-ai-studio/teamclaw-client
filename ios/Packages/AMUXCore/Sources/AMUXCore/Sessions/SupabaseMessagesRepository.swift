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
    public let model: String?
}

public protocol MessagesRepository: Sendable {
    func listForSession(sessionID: String) async throws -> [MessageRecord]
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

    public func listForSession(sessionID: String) async throws -> [MessageRecord] {
        let rows: [MessageRow] = try await client
            .from("messages")
            .select("id, session_id, sender_actor_id, kind, content, created_at, model")
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
                model: row.model
            )
        }
    }
}

private struct MessageRow: Decodable, Sendable {
    let id: String
    let sessionID: String
    let senderActorID: String
    let kind: String
    let content: String
    let createdAt: Date
    let model: String?

    enum CodingKeys: String, CodingKey {
        case id
        case sessionID = "session_id"
        case senderActorID = "sender_actor_id"
        case kind
        case content
        case createdAt = "created_at"
        case model
    }
}
