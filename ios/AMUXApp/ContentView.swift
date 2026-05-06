import SwiftUI
import UIKit
import os
import AMUXCore
import AMUXUI

private let logger = Logger(subsystem: "com.amux.app", category: "MQTT")

struct ContentView: View {
    let pairing: PairingManager
    @State private var mqtt = MQTTService()
    @State private var teamclawService = TeamclawService()
    @State private var onboarding: AppOnboardingCoordinator
    @State private var isConnecting = false
    @State private var connectTask: Task<Void, Never>?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var modelContext

    init(pairing: PairingManager) {
        self.pairing = pairing

        do {
            let store = try SupabaseAppOnboardingStore()
            _onboarding = State(initialValue: AppOnboardingCoordinator(store: store))
        } catch {
            _onboarding = State(
                initialValue: AppOnboardingCoordinator(
                    store: FailingOnboardingStore(error: error)
                )
            )
        }
    }

    var body: some View {
        Group {
            switch onboarding.route {
            case .loading:
                ProgressView("Setting up AMUX…")
            case .needsAuth:
                WelcomeView(coordinator: onboarding)
            case .createTeam:
                CreateTeamView(coordinator: onboarding)
            case .ready:
                RootTabView(
                    mqtt: mqtt,
                    pairing: pairing,
                    teamclawService: teamclawService,
                    activeTeam: onboarding.currentContext?.team,
                    currentActorID: onboarding.currentContext?.memberActorID,
                    onReconnect: {
                        forceReconnect()
                    },
                    onSignOut: {
                        signOut()
                    }
                )
                .environment(onboarding)
                .task {
                    if let team = onboarding.currentContext?.team {
                        OnboardingLocalCacheBootstrapper.ensureWorkspaceExists(team: team, modelContext: modelContext)
                    }
                    await connectMQTT()
                }
            case .failed:
                OnboardingErrorView(
                    message: onboarding.errorMessage ?? "Unknown setup error."
                ) {
                    Task { await onboarding.bootstrap() }
                }
            }
        }
        .task {
            await onboarding.bootstrap()
        }
        .onChange(of: onboarding.pendingCreatedTeam) { _, createdTeam in
            guard let createdTeam else { return }
            OnboardingLocalCacheBootstrapper.prime(createdTeam: createdTeam, modelContext: modelContext)
        }
        .onChange(of: pairing.isPaired) { _, paired in
            guard paired else { return }
            Task { await connectMQTT() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .amuxAuthCallbackReceived)) { notification in
            guard let url = notification.object as? URL else { return }
            Task { await onboarding.handleAuthCallback(url: url) }
        }
        .onChange(of: scenePhase) { _, phase in
            // iOS freezes sockets when backgrounded but rarely delivers a
            // clean disconnect callback, so `connectionState` can stay
            // `.connected` on a dead socket ("zombie"). On foreground we
            // force a full reconnect regardless of reported state; the
            // RuntimeDetailViewModel loop will resubscribe and trigger an
            // incremental history sync once MQTT is back up.
            if phase == .active && pairing.isPaired && onboarding.route == .ready {
                logger.info("App became active, forcing MQTT reconnect…")
                forceReconnect()
            }
        }
    }

    private func signOut() {
        connectTask?.cancel()
        isConnecting = false
        // Wipe the SwiftData cache before invalidating the session — every
        // model in the container is just a snapshot of remote state for the
        // signed-in user, and leaving rows around lets the next signed-in
        // user (or the same user after switching teams via invite) see stale
        // actors / sessions / workspaces until a per-team reload overwrites
        // them. The ones we don't actively reload (other-team rows) never get
        // cleared otherwise.
        wipeLocalCache()
        Task {
            await mqtt.disconnect()
            await onboarding.signOut()
        }
    }

    private func wipeLocalCache() {
        do {
            try modelContext.delete(model: Runtime.self)
            try modelContext.delete(model: AgentEvent.self)
            try modelContext.delete(model: CachedActor.self)
            try modelContext.delete(model: CachedAgentRuntime.self)
            try modelContext.delete(model: Workspace.self)
            try modelContext.delete(model: Session.self)
            try modelContext.delete(model: SessionMessage.self)
            try modelContext.delete(model: SessionIdea.self)
            try modelContext.save()
        } catch {
            logger.error("Failed to wipe local cache on sign-out: \(error)")
        }
    }

    /// User-initiated reconnect: cancels any in-flight connect Task (so a
    /// hung MQTTService.connect can't leave `isConnecting` stuck `true`),
    /// clears the flag, then disconnects and reconnects.
    private func forceReconnect() {
        connectTask?.cancel()
        isConnecting = false
        connectTask = Task {
            await mqtt.disconnect()
            await connectMQTT()
        }
    }

    private func connectMQTT() async {
        guard onboarding.route == .ready, pairing.isPaired, !isConnecting else { return }
        isConnecting = true
        defer { isConnecting = false }

        let token: String
        do {
            token = try await onboarding.accessToken()
        } catch {
            logger.error("Failed to get access token for MQTT: \(error)")
            return
        }

        let userID = onboarding.currentContext?.memberActorID ?? "amux-ios"
        let clientId = "amux-ios-\(userID.prefix(8))"
        logger.info("Connecting to \(pairing.brokerHost):\(pairing.brokerPort) tls=\(pairing.useTLS)")
        do {
            try await mqtt.connect(
                host: pairing.brokerHost, port: pairing.brokerPort,
                username: userID, password: token,
                clientId: clientId, useTLS: pairing.useTLS
            )
            logger.info("MQTT connected")
            // TeamclawService.start is invoked from RootTabView.configureStores
            // once ConnectedAgentsStore has loaded; it owns its own
            // wait-for-MQTT loop so racing this connect call is safe.
        } catch {
            logger.error("MQTT connect failed: \(error)")
        }
    }
}

private actor FailingOnboardingStore: AppOnboardingStore {
    let error: Error

    init(error: Error) {
        self.error = error
    }

    func ensureSession() async throws {
        throw error
    }

    func loadBootstrap() async throws -> AppBootstrap {
        throw error
    }

    func createTeam(named name: String) async throws -> CreatedTeam {
        throw error
    }

    func signIn(email: String, password: String) async throws { throw error }
    func signUp(email: String, password: String) async throws { throw error }
    func sendMagicLink(email: String) async throws { throw error }
    func signInWithAppleCredential(idToken: String, nonce: String) async throws { throw error }
    func signInWithGoogle() async throws { throw error }
    func handleAuthCallback(url: URL) async throws { throw error }
    func accessToken() async throws -> String { throw error }
    func signOut() async throws { throw error }
    func signInAnonymously() async throws { throw error }
    func isAnonymous() async -> Bool { false }
    func upgradeWithPassword(email: String, password: String) async throws { throw error }
    func upgradeWithAppleCredential(idToken: String, nonce: String) async throws { throw error }
    func claimInvite(token: String) async throws -> ClaimResult { throw error }
}
