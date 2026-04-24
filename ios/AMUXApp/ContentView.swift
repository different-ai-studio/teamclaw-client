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
                    }
                )
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
        logger.info("Connecting to \(pairing.brokerHost):\(pairing.brokerPort) tls=\(pairing.useTLS) user=\(pairing.username)")
        do {
            logger.info("Calling mqtt.connect()...")
            let clientId = "amux-ios-\(pairing.authToken.prefix(8))"
            try await mqtt.connect(host: pairing.brokerHost, port: pairing.brokerPort,
                username: pairing.username, password: pairing.password,
                clientId: clientId, useTLS: pairing.useTLS)
            logger.info("mqtt.connect() returned successfully")

            // Legacy PeerAnnounce publish on device/{id}/collab was retired in
            // Phase 3 — the daemon no longer subscribes to that topic. Broker-
            // level JWT auth now handles peer authentication; peer presence is
            // driven by `device/{id}/peers` retained state published by the
            // daemon.
            logger.info("MQTT connected")

            // Start TeamclawService for work items and collab sessions
            teamclawService.start(
                mqtt: mqtt,
                teamId: onboarding.currentContext?.team.id ?? "",
                deviceId: pairing.deviceId,
                peerId: "ios-\(pairing.authToken.prefix(6))",
                modelContext: modelContext
            )
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
}
