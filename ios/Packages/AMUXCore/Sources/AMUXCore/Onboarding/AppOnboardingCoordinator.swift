import Foundation
import Observation

public struct TeamSummary: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let slug: String
    public let role: String

    public init(id: String, name: String, slug: String, role: String) {
        self.id = id
        self.name = name
        self.slug = slug
        self.role = role
    }
}

public struct AppBootstrap: Equatable, Sendable {
    public let memberActorID: String?
    public let teams: [TeamSummary]

    public init(memberActorID: String?, teams: [TeamSummary]) {
        self.memberActorID = memberActorID
        self.teams = teams
    }
}

public struct CreatedTeam: Equatable, Sendable {
    public let team: TeamSummary
    public let memberActorID: String
    public let workspaceID: String
    public let workspaceName: String

    public init(team: TeamSummary, memberActorID: String, workspaceID: String, workspaceName: String) {
        self.team = team
        self.memberActorID = memberActorID
        self.workspaceID = workspaceID
        self.workspaceName = workspaceName
    }
}

public struct AppContext: Equatable, Sendable {
    public let team: TeamSummary
    public let memberActorID: String

    public init(team: TeamSummary, memberActorID: String) {
        self.team = team
        self.memberActorID = memberActorID
    }
}

public enum AuthRequired: Error {
    case notAuthenticated
}

public enum AppOnboardingRoute: Equatable, Sendable {
    case loading
    case needsAuth
    case createTeam
    case ready
    case failed
}

public protocol AppOnboardingStore: Sendable {
    func ensureSession() async throws
    func loadBootstrap() async throws -> AppBootstrap
    func createTeam(named name: String) async throws -> CreatedTeam

    // Auth sign-in methods
    func signIn(email: String, password: String) async throws
    func signUp(email: String, password: String) async throws
    func sendMagicLink(email: String) async throws
    func signInWithAppleCredential(idToken: String, nonce: String) async throws
    func signInWithGoogle() async throws
    func signInAnonymously() async throws
    func handleAuthCallback(url: URL) async throws
    func accessToken() async throws -> String
    func signOut() async throws

    // True iff the current session belongs to an anonymous user
    // (`auth.users.is_anonymous`). Returns false when no session exists.
    func isAnonymous() async -> Bool

    // Promote the current anonymous session to a permanent account by
    // attaching credentials. Same auth.users.id, so all team / actor / access
    // rows the user accumulated as anonymous are preserved.
    func upgradeWithPassword(email: String, password: String) async throws
    func upgradeWithAppleCredential(idToken: String, nonce: String) async throws
}

@Observable
@MainActor
public final class AppOnboardingCoordinator {
    public var route: AppOnboardingRoute = .loading
    public var currentContext: AppContext?
    public var pendingCreatedTeam: CreatedTeam?
    public var errorMessage: String?
    public var pendingMagicLinkEmail: String?
    public var isBusy = false
    /// True iff the current session is an anonymous Supabase user. UI uses
    /// this to surface the "upgrade your account" affordance.
    public var isAnonymous: Bool = false

    private let store: AppOnboardingStore

    public init(store: AppOnboardingStore) {
        self.store = store
    }

    public func bootstrap() async {
        guard !isBusy else { return }
        isBusy = true
        route = .loading
        errorMessage = nil
        defer { isBusy = false }

        do {
            try await store.ensureSession()
            isAnonymous = await store.isAnonymous()
            let bootstrap = try await store.loadBootstrap()
            pendingCreatedTeam = nil

            if let team = bootstrap.teams.first,
               let memberActorID = bootstrap.memberActorID {
                currentContext = AppContext(team: team, memberActorID: memberActorID)
                route = .ready
                return
            }

            // No team yet. For anonymous users, auto-create one with a
            // humanized random name so the "try it first" path lands
            // straight in the app instead of showing the team-name screen.
            if isAnonymous {
                let name = RandomTeamName.generate()
                let created = try await store.createTeam(named: name)
                pendingCreatedTeam = created
                currentContext = AppContext(team: created.team, memberActorID: created.memberActorID)
                route = .ready
                return
            }

            currentContext = nil
            route = .createTeam
        } catch is AuthRequired {
            currentContext = nil
            isAnonymous = false
            route = .needsAuth
        } catch {
            currentContext = nil
            isAnonymous = false
            route = .failed
            errorMessage = error.localizedDescription
        }
    }

    public func createTeam(named rawName: String) async {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            errorMessage = "Team name is required."
            route = .createTeam
            return
        }

        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }

        do {
            let created = try await store.createTeam(named: name)
            pendingCreatedTeam = created
            currentContext = AppContext(team: created.team, memberActorID: created.memberActorID)
            route = .ready
        } catch {
            route = .createTeam
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Auth sign-in

    public func signIn(email: String, password: String) async {
        await performAuth { try await self.store.signIn(email: email, password: password) }
    }

    public func signUp(email: String, password: String) async {
        await performAuth { try await self.store.signUp(email: email, password: password) }
    }

    public func sendMagicLink(email: String) async {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            try await store.sendMagicLink(email: email)
            pendingMagicLinkEmail = email
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func signInWithApple() async {
#if os(iOS)
        await performAuth {
            let (idToken, nonce) = try await AppleSignInHandler.shared.request()
            try await self.store.signInWithAppleCredential(idToken: idToken, nonce: nonce)
        }
#endif
    }

    public func signInWithGoogle() async {
        await performAuth { try await self.store.signInWithGoogle() }
    }

    public func signInAnonymously() async {
        await performAuth { try await self.store.signInAnonymously() }
    }

    // MARK: - Anonymous account upgrade

    /// Promote the current anonymous session to an email/password account.
    /// On success the user_id is unchanged, so existing team / actor rows are
    /// retained. Triggers a re-bootstrap to refresh `isAnonymous`.
    public func upgradeWithPassword(email: String, password: String) async {
        await performAuth { try await self.store.upgradeWithPassword(email: email, password: password) }
    }

    /// Same as `upgradeWithPassword` but linking an Apple identity instead.
    public func upgradeWithApple() async {
#if os(iOS)
        await performAuth {
            let (idToken, nonce) = try await AppleSignInHandler.shared.request()
            try await self.store.upgradeWithAppleCredential(idToken: idToken, nonce: nonce)
        }
#endif
    }

    public func accessToken() async throws -> String {
        try await store.accessToken()
    }

    public func signOut() async {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        do {
            try await store.signOut()
        } catch {
            errorMessage = error.localizedDescription
        }
        currentContext = nil
        pendingCreatedTeam = nil
        pendingMagicLinkEmail = nil
        isAnonymous = false
        route = .needsAuth
        isBusy = false
    }

    public func handleAuthCallback(url: URL) async {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        do {
            try await store.handleAuthCallback(url: url)
            pendingMagicLinkEmail = nil
            isBusy = false
            await bootstrap()
        } catch {
            isBusy = false
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Private helpers

    private func performAuth(_ action: @escaping () async throws -> Void) async {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        do {
            try await action()
            isBusy = false
            await bootstrap()
        } catch {
            isBusy = false
            errorMessage = error.localizedDescription
        }
    }
}
