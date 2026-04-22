import Foundation
import Supabase

public enum InviteAgentServiceError: LocalizedError {
    case emptyResponse
    case invalidJoinURL

    public var errorDescription: String? {
        switch self {
        case .emptyResponse:
            return "create_daemon_invite returned no rows."
        case .invalidJoinURL:
            return "Failed to build amux://join deeplink URL."
        }
    }
}

public struct InvitePayload: Codable, Sendable {
    public let inviteToken: UUID
    public let agentId: String
    public let joinURL: URL
    public let expiresAt: Date

    public init(inviteToken: UUID, agentId: String, joinURL: URL, expiresAt: Date) {
        self.inviteToken = inviteToken
        self.agentId = agentId
        self.joinURL = joinURL
        self.expiresAt = expiresAt
    }
}

public actor InviteAgentService {
    private let client: SupabaseClient
    private let supabaseURL: URL
    private let anonKey: String

    public init(configuration: SupabaseProjectConfiguration) {
        self.client = SupabaseClient(
            supabaseURL: configuration.url,
            supabaseKey: configuration.publishableKey
        )
        self.supabaseURL = configuration.url
        self.anonKey = configuration.publishableKey
    }

    public init() throws {
        let configuration = try SupabaseProjectConfiguration.fromMainBundle()
        self.client = SupabaseClient(
            supabaseURL: configuration.url,
            supabaseKey: configuration.publishableKey
        )
        self.supabaseURL = configuration.url
        self.anonKey = configuration.publishableKey
    }

    public func createInvite(teamID: UUID, displayName: String) async throws -> InvitePayload {
        let rows: [Row] = try await client
            .rpc(
                "create_daemon_invite",
                params: Params(
                    teamID: teamID.uuidString.lowercased(),
                    displayName: displayName
                )
            )
            .execute()
            .value

        guard let row = rows.first else {
            throw InviteAgentServiceError.emptyResponse
        }

        let joinURL = Self.buildJoinURL(
            token: row.inviteToken,
            supabaseURL: supabaseURL,
            anonKey: anonKey
        )

        return InvitePayload(
            inviteToken: row.inviteToken,
            agentId: row.agentId,
            joinURL: joinURL,
            expiresAt: row.expiresAt
        )
    }

    /// Builds the `amux://join?token=...&url=...&anon=...` deeplink that
    /// `amuxd init <url>` parses during daemon onboarding. The supabase URL
    /// and anon key are percent-encoded so callers (including the daemon's
    /// URL parser) receive unambiguous values.
    public static func buildJoinURL(token: UUID, supabaseURL: URL, anonKey: String) -> URL {
        // Percent-encode `:` and `/` in the URL value so the embedded scheme
        // doesn't collide with the outer `amux://...` query parsing. Keep the
        // RFC 3986 unreserved characters (`-`, `.`, `_`, `~`) as literal so
        // host components like `x.supabase.co` survive untouched.
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let encodedURL = supabaseURL.absoluteString
            .addingPercentEncoding(withAllowedCharacters: allowed) ?? supabaseURL.absoluteString
        let encodedAnon = anonKey
            .addingPercentEncoding(withAllowedCharacters: allowed) ?? anonKey
        let tokenString = token.uuidString.lowercased()

        var components = URLComponents()
        components.scheme = "amux"
        components.host = "join"
        components.percentEncodedQueryItems = [
            URLQueryItem(name: "token", value: tokenString),
            URLQueryItem(name: "url", value: encodedURL),
            URLQueryItem(name: "anon", value: encodedAnon),
        ]

        if let url = components.url {
            return url
        }
        // URLComponents with a static scheme/host and valid query items should
        // never fail to produce a URL; fall back to a best-effort string build.
        return URL(
            string: "amux://join?token=\(tokenString)&url=\(encodedURL)&anon=\(encodedAnon)"
        )!
    }
}

private struct Params: Encodable {
    let teamID: String
    let displayName: String

    enum CodingKeys: String, CodingKey {
        case teamID = "p_team_id"
        case displayName = "p_display_name"
    }
}

private struct Row: Decodable, Sendable {
    let inviteToken: UUID
    let agentId: String
    let expiresAt: Date

    enum CodingKeys: String, CodingKey {
        case inviteToken = "invite_token"
        case agentId = "agent_id"
        case expiresAt = "expires_at"
    }
}
