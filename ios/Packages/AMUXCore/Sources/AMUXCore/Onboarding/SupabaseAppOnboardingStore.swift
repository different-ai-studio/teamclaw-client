import Foundation
import Supabase

public enum SupabaseProjectConfigurationError: LocalizedError {
    case missingURL
    case invalidURL(String)
    case missingPublishableKey

    public var errorDescription: String? {
        switch self {
        case .missingURL:
            return "SUPABASE_URL is missing from Info.plist."
        case .invalidURL(let value):
            return "SUPABASE_URL is invalid: \(value)"
        case .missingPublishableKey:
            return "SUPABASE_PUBLISHABLE_KEY is missing from Info.plist."
        }
    }
}

public struct SupabaseProjectConfiguration: Sendable {
    public let url: URL
    public let publishableKey: String

    public init(url: URL, publishableKey: String) {
        self.url = url
        self.publishableKey = publishableKey
    }

    /// Resolve the effective Supabase config. User-overridden values in
    /// UserDefaults (set via the Settings "Supabase Server" editor) win over
    /// Info.plist bake-ins, which in turn win over no config at all.
    public static func fromMainBundle() throws -> Self {
        let bundle = Bundle.main
        let defaults = UserDefaults.standard

        let rawURL = (defaults.string(forKey: SupabaseServerStore.urlKey)
                      ?? bundle.object(forInfoDictionaryKey: "SUPABASE_URL") as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawURL.isEmpty else {
            throw SupabaseProjectConfigurationError.missingURL
        }
        guard let url = URL(string: rawURL) else {
            throw SupabaseProjectConfigurationError.invalidURL(rawURL)
        }
        let publishableKey = (defaults.string(forKey: SupabaseServerStore.keyKey)
                              ?? bundle.object(forInfoDictionaryKey: "SUPABASE_PUBLISHABLE_KEY") as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !publishableKey.isEmpty else {
            throw SupabaseProjectConfigurationError.missingPublishableKey
        }
        return Self(url: url, publishableKey: publishableKey)
    }
}

/// Persists Supabase URL + publishable key overrides in UserDefaults. Falls
/// back to Info.plist bake-ins when nothing is stored. Changing values requires
/// an app relaunch — existing Supabase clients are captured with the old
/// config.
public enum SupabaseServerStore {
    public static let urlKey = "amux_supabase_url"
    public static let keyKey = "amux_supabase_key"

    public static func currentURL() -> String {
        UserDefaults.standard.string(forKey: urlKey)
            ?? Bundle.main.object(forInfoDictionaryKey: "SUPABASE_URL") as? String
            ?? ""
    }

    public static func currentKey() -> String {
        UserDefaults.standard.string(forKey: keyKey)
            ?? Bundle.main.object(forInfoDictionaryKey: "SUPABASE_PUBLISHABLE_KEY") as? String
            ?? ""
    }

    public static func save(url: String, key: String) {
        let d = UserDefaults.standard
        d.set(url.trimmingCharacters(in: .whitespacesAndNewlines), forKey: urlKey)
        d.set(key.trimmingCharacters(in: .whitespacesAndNewlines), forKey: keyKey)
    }
}

public actor SupabaseAppOnboardingStore: AppOnboardingStore {
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

    public func ensureSession() async throws {
        if client.auth.currentSession != nil {
            return
        }

        _ = try await client.auth.signInAnonymously()
    }

    public func loadBootstrap() async throws -> AppBootstrap {
        let session = try await client.auth.session
        let userID = session.user.id.uuidString.lowercased()

        let actors: [MemberRow] = try await client
            .from("actors")
            .select("id")
            .eq("user_id", value: userID)
            .eq("actor_type", value: "member")
            .limit(1)
            .execute()
            .value

        guard let member = actors.first else {
            return AppBootstrap(memberActorID: nil, teams: [])
        }

        let memberships: [MembershipRow] = try await client
            .from("team_members")
            .select(
                """
                role,
                teams!inner (
                  id,
                  name,
                  slug
                )
                """
            )
            .eq("member_id", value: member.id)
            .execute()
            .value

        let teams = memberships.map {
            TeamSummary(
                id: $0.teams.id,
                name: $0.teams.name,
                slug: $0.teams.slug,
                role: $0.role
            )
        }

        return AppBootstrap(memberActorID: member.id, teams: teams)
    }

    public func createTeam(named name: String) async throws -> CreatedTeam {
        let rows: [CreatedTeamRow] = try await client
            .rpc(
                "create_team",
                params: ["p_name": name]
            )
            .execute()
            .value

        guard let row = rows.first else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: [], debugDescription: "create_team returned no rows")
            )
        }

        return CreatedTeam(
            team: TeamSummary(
                id: row.teamID,
                name: row.teamName,
                slug: row.teamSlug,
                role: row.role
            ),
            memberActorID: row.memberID,
            workspaceID: row.workspaceID,
            workspaceName: row.workspaceName
        )
    }
}

private struct MemberRow: Decodable, Sendable {
    let id: String
}

private struct MembershipRow: Decodable, Sendable {
    let role: String
    let teams: TeamRow
}

private struct TeamRow: Decodable, Sendable {
    let id: String
    let name: String
    let slug: String
}

private struct CreatedTeamRow: Decodable, Sendable {
    let teamID: String
    let teamName: String
    let teamSlug: String
    let memberID: String
    let role: String
    let workspaceID: String
    let workspaceName: String

    enum CodingKeys: String, CodingKey {
        case teamID = "team_id"
        case teamName = "team_name"
        case teamSlug = "team_slug"
        case memberID = "member_id"
        case role
        case workspaceID = "workspace_id"
        case workspaceName = "workspace_name"
    }
}
