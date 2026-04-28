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
    let actorStore: ActorStore?
    var onSignOut: (() -> Void)?

    @Environment(\.modelContext) private var modelContext

    @State private var showSettings = false
    @State private var showNewSession = false
    @State private var showInvite = false
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
                actorStore: ActorStore? = nil,
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
        self.actorStore = actorStore
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
                actorId: "ios-\(pairing.authToken.prefix(6))",
                noAccessibleAgent: connectedAgentsStore?.agents.isEmpty == true,
                onInviteFirstAgent: actorStore == nil ? nil : { showInvite = true }
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
                        connectedAgentsStore: connectedAgentsStore
                    )
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(connectedAgentsStore: connectedAgentsStore,
                             activeTeam: activeTeam,
                             onSignOut: onSignOut)
            }
            .sheet(isPresented: $showNewSession) {
                NewSessionSheet(mqtt: mqtt,
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
            .sheet(isPresented: $showInvite) {
                if let actorStore {
                    MemberInviteSheet(store: actorStore)
                }
            }
            .task {
                viewModel.start(
                    mqtt: mqtt,
                    teamID: activeTeam?.id ?? "",
                    connectedAgentsStore: connectedAgentsStore,
                    modelContext: modelContext,
                    teamclawService: teamclawService
                )
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

    @Environment(\.modelContext) private var modelContext
    @State private var runtime: Runtime?
    @State private var session: Session?
    @State private var attemptedLoad = false

    var body: some View {
        Group {
            if let session {
                RuntimeDetailView(
                    session: session,
                    mqtt: mqtt,
                    peerId: "ios-\(pairing.authToken.prefix(6))",
                    teamclawService: nil,
                    connectedAgentsStore: connectedAgentsStore
                )
                .id("agent-session:\(session.sessionId)")
            } else if let runtime {
                RuntimeDetailView(
                    runtime: runtime,
                    mqtt: mqtt,
                    peerId: "ios-\(pairing.authToken.prefix(6))",
                    connectedAgentsStore: connectedAgentsStore
                )
                .id("agent:\(runtime.runtimeId)")
            } else if attemptedLoad {
                Text("Agent not found")
            } else {
                ProgressView()
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

        // Same flash-suppression trick as CollabSessionDestinationView:
        // hold a ProgressView until SwiftData has actually been queried,
        // so newly-routed runtime IDs don't briefly render "Agent not
        // found" before the row lands.
        attemptedLoad = true
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
                                      peerId: "ios-\(pairing.authToken.prefix(6))",
                                      teamclawService: teamclawService,
                                      connectedAgentsStore: connectedAgentsStore)
                    .id("collab-agent:\(session.sessionId)")
                }
            } else {
                // Don't flash "Session not found" while SwiftData /
                // Supabase round-trip is still in flight (e.g. right
                // after navigating from NewSessionSheet). Only declare
                // missing once we've actually attempted a refresh.
                Group {
                    if attemptedRefresh {
                        Text("Session not found")
                    } else {
                        ProgressView()
                    }
                }
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

        // Run the refresh + reload BEFORE flipping `attemptedRefresh`. The
        // flag gates the "Session not found" copy, so flipping it before
        // the network round-trip completes flashes that copy on screen
        // for the duration of `refreshSessionsFromBackend()` — exactly the
        // bug we're trying to suppress.
        await refreshSessionsFromBackend()
        await loadSession()
        await MainActor.run {
            attemptedRefresh = true
        }
        if session == nil {
            await MainActor.run {
                logKnownSessions()
            }
        }
    }
}
