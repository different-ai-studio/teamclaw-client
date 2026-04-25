import SwiftUI
import SwiftData
import AMUXCore
import os

private let sessionsTabLogger = Logger(subsystem: "com.amux.app", category: "SessionsTab")

public struct SessionsTab: View {
    let mqtt: MQTTService
    let pairing: PairingManager
    let teamclawService: TeamclawService?
    let activeTeam: TeamSummary?
    let currentActorID: String?
    @Bindable var viewModel: SessionListViewModel
    let refreshSessionsFromBackend: () async -> Void
    let connectedAgentsStore: ConnectedAgentsStore?
    var onReconnect: (() -> Void)?
    var onSignOut: (() -> Void)?

    @Environment(\.modelContext) private var modelContext

    @State private var showSettings = false
    @State private var showNewSession = false
    @Binding var navigationPath: [String]

    @State private var isEditing = false
    @State private var selectedIDs: Set<String> = []

    @Namespace private var sheetTransition

    public init(mqtt: MQTTService,
                pairing: PairingManager,
                teamclawService: TeamclawService?,
                activeTeam: TeamSummary?,
                currentActorID: String?,
                viewModel: SessionListViewModel,
                refreshSessionsFromBackend: @escaping () async -> Void,
                navigationPath: Binding<[String]>,
                connectedAgentsStore: ConnectedAgentsStore? = nil,
                onReconnect: (() -> Void)? = nil,
                onSignOut: (() -> Void)? = nil) {
        self.mqtt = mqtt
        self.pairing = pairing
        self.teamclawService = teamclawService
        self.activeTeam = activeTeam
        self.currentActorID = currentActorID
        self.viewModel = viewModel
        self.refreshSessionsFromBackend = refreshSessionsFromBackend
        self._navigationPath = navigationPath
        self.connectedAgentsStore = connectedAgentsStore
        self.onReconnect = onReconnect
        self.onSignOut = onSignOut
    }

    public var body: some View {
        NavigationStack(path: $navigationPath) {
            SessionListContent(
                viewModel: viewModel,
                refreshSessionsFromBackend: refreshSessionsFromBackend,
                navigationPath: $navigationPath,
                isEditing: $isEditing,
                selectedIDs: $selectedIDs,
                teamclawService: teamclawService,
                actorId: "ios-\(pairing.authToken.prefix(6))"
            )
            .navigationTitle("Sessions")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape").font(.title3).foregroundStyle(.primary)
                    }
                    .buttonStyle(.plain)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showNewSession = true } label: {
                        Image(systemName: "square.and.pencil").font(.title3).foregroundStyle(.primary)
                    }
                    .accessibilityIdentifier("sessions.newSessionButton")
                    .buttonStyle(.plain)
                    .matchedTransitionSource(id: "newSession", in: sheetTransition)
                }
            }
            .navigationDestination(for: String.self) { id in
                if id.hasPrefix("collab:") {
                    let sessionId = String(id.dropFirst("collab:".count))
                    CollabSessionDestinationView(
                        sessionId: sessionId,
                        mqtt: mqtt,
                        pairing: pairing,
                        teamclawService: teamclawService,
                        currentActorID: currentActorID,
                        refreshSessionsFromBackend: refreshSessionsFromBackend,
                        navigationPath: $navigationPath,
                        connectedAgentsStore: connectedAgentsStore
                    )
                } else {
                    RuntimeDestinationView(
                        runtimeId: id,
                        mqtt: mqtt,
                        pairing: pairing,
                        navigationPath: $navigationPath,
                        connectedAgentsStore: connectedAgentsStore,
                        allAgentIds: viewModel.runtimes.map(\.runtimeId)
                    )
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(pairing: pairing,
                             connectedAgentsStore: connectedAgentsStore,
                             activeTeam: activeTeam,
                             onReconnect: onReconnect,
                             onSignOut: onSignOut)
            }
            .sheet(isPresented: $showNewSession) {
                NewSessionSheet(mqtt: mqtt, deviceId: pairing.deviceId,
                               peerId: "ios-\(pairing.authToken.prefix(6))",
                               teamclawService: teamclawService,
                               teamID: activeTeam?.id ?? "",
                               currentActorID: currentActorID,
                               isAgentAvailable: pairing.isPaired,
                               connectedAgentsStore: connectedAgentsStore,
                               viewModel: viewModel) { agentId in
                    navigationPath = [agentId]
                }
                .modifier(ZoomTransitionModifier(sourceID: "newSession", namespace: sheetTransition))
            }
            .task {
                viewModel.start(mqtt: mqtt, deviceId: pairing.deviceId, modelContext: modelContext, teamclawService: teamclawService)
            }
            .onChange(of: teamclawService?.sessions.count) {
                viewModel.reloadSessions(modelContext: modelContext)
            }
        }
    }
}

private struct RuntimeDestinationView: View {
    let runtimeId: String
    let mqtt: MQTTService
    let pairing: PairingManager
    @Binding var navigationPath: [String]
    let connectedAgentsStore: ConnectedAgentsStore?
    let allAgentIds: [String]

    @Environment(\.modelContext) private var modelContext
    @State private var runtime: Runtime?
    @State private var session: Session?

    var body: some View {
        Group {
            if let session {
                RuntimeDetailView(
                    session: session,
                    mqtt: mqtt,
                    deviceId: pairing.deviceId,
                    peerId: "ios-\(pairing.authToken.prefix(6))",
                    teamclawService: nil,
                    navigationPath: $navigationPath,
                    connectedAgentsStore: connectedAgentsStore
                )
                .id("agent-session:\(session.sessionId)")
            } else if let runtime {
                RuntimeDetailView(
                    runtime: runtime,
                    mqtt: mqtt,
                    deviceId: pairing.deviceId,
                    peerId: "ios-\(pairing.authToken.prefix(6))",
                    allAgentIds: allAgentIds,
                    navigationPath: $navigationPath,
                    connectedAgentsStore: connectedAgentsStore
                )
                .id("agent:\(runtime.runtimeId)")
            } else {
                Text("Agent not found")
            }
        }
        .task(id: runtimeId) {
            await loadDestination()
        }
    }

    @MainActor
    private func loadDestination() {
        let runtimeDescriptor = FetchDescriptor<Runtime>(
            predicate: #Predicate { $0.runtimeId == runtimeId }
        )
        runtime = (try? modelContext.fetch(runtimeDescriptor))?.first

        let sessionDescriptor = FetchDescriptor<Session>()
        session = (try? modelContext.fetch(sessionDescriptor))?.first(where: { $0.primaryAgentId == runtimeId })
    }
}

private struct CollabSessionDestinationView: View {
    let sessionId: String
    let mqtt: MQTTService
    let pairing: PairingManager
    let teamclawService: TeamclawService?
    let currentActorID: String?
    let refreshSessionsFromBackend: () async -> Void
    @Binding var navigationPath: [String]
    let connectedAgentsStore: ConnectedAgentsStore?

    @Environment(\.modelContext) private var modelContext

    @State private var session: Session?
    @State private var attemptedRefresh = false

    var body: some View {
        Group {
            if let session {
                if session.primaryAgentId == nil || !pairing.isPaired {
                    SessionView(
                        session: session,
                        teamclawService: teamclawService,
                        currentActorID: currentActorID
                    )
                    .id("session:\(session.sessionId)")
                } else {
                    RuntimeDetailView(session: session, mqtt: mqtt,
                                      deviceId: pairing.deviceId,
                                      peerId: "ios-\(pairing.authToken.prefix(6))",
                                      teamclawService: teamclawService,
                                      navigationPath: $navigationPath,
                                      connectedAgentsStore: connectedAgentsStore)
                    .id("collab-agent:\(session.sessionId)")
                }
            } else {
                Text("Session not found")
                    .task(id: sessionId) {
                        await reloadSessionIfNeeded()
                    }
            }
        }
        .task(id: sessionId) {
            await loadSession()
        }
    }

    @MainActor
    private func fetchSession() -> Session? {
        let descriptor = FetchDescriptor<Session>(
            predicate: #Predicate { $0.sessionId == sessionId }
        )
        return (try? modelContext.fetch(descriptor))?.first
    }

    private func loadSession() async {
        await MainActor.run {
            session = fetchSession()
        }
    }

    @MainActor
    private func logKnownSessions() {
        let knownSessions: [Session] = (try? modelContext.fetch(FetchDescriptor<Session>())) ?? []
        let knownIDs = knownSessions.map(\.sessionId).joined(separator: ",")
        sessionsTabLogger.error(
            "session lookup failed requested=\(sessionId, privacy: .public) knownCount=\(knownSessions.count) knownIDs=\(knownIDs, privacy: .public)"
        )
    }

    private func reloadSessionIfNeeded() async {
        await loadSession()
        guard session == nil, !attemptedRefresh else {
            if session == nil {
                await MainActor.run {
                    logKnownSessions()
                }
            }
            return
        }

        await MainActor.run {
            attemptedRefresh = true
        }
        await refreshSessionsFromBackend()
        await loadSession()
        if session == nil {
            await MainActor.run {
                logKnownSessions()
            }
        }
    }
}
