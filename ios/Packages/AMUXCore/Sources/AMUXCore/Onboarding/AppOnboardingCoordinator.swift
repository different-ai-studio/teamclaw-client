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
    func handleAuthCallback(url: URL) async throws
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
            let bootstrap = try await store.loadBootstrap()
            pendingCreatedTeam = nil

            guard let team = bootstrap.teams.first,
                  let memberActorID = bootstrap.memberActorID else {
                currentContext = nil
                route = .createTeam
                return
            }

            currentContext = AppContext(team: team, memberActorID: memberActorID)
            route = .ready
        } catch is AuthRequired {
            currentContext = nil
            route = .needsAuth
        } catch {
            currentContext = nil
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
}
