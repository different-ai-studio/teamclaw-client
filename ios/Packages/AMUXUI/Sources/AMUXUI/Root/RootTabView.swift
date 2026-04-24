import SwiftUI
import AMUXCore

public struct RootTabView: View {
    let mqtt: MQTTService
    let pairing: PairingManager
    let teamclawService: TeamclawService?
    let activeTeam: TeamSummary?
    let currentActorID: String?
    var onReconnect: (() -> Void)?

    @Environment(\.modelContext) private var modelContext
    @State private var viewModel = SessionListViewModel()
    @SceneStorage("rootTab") private var selection: AppTab = .sessions
    @State private var sessionsPath: [String] = []
    @State private var actorStore: ActorStore?
    @State private var connectedAgentsStore: ConnectedAgentsStore?
    @State private var sessionIDsRepo: SupabaseSessionIDsRepository?
    @State private var sessionsRepo: SupabaseSessionsRepository?

    public init(mqtt: MQTTService,
                pairing: PairingManager,
                teamclawService: TeamclawService?,
                activeTeam: TeamSummary? = nil,
                currentActorID: String? = nil,
                onReconnect: (() -> Void)? = nil) {
        self.mqtt = mqtt
        self.pairing = pairing
        self.teamclawService = teamclawService
        self.activeTeam = activeTeam
        self.currentActorID = currentActorID
        self.onReconnect = onReconnect
    }

    public var body: some View {
        TabView(selection: $selection) {
            Tab("Sessions", systemImage: "bubble.left.and.bubble.right", value: AppTab.sessions) {
                SessionsTab(mqtt: mqtt,
                            pairing: pairing,
                            teamclawService: teamclawService,
                            activeTeam: activeTeam,
                            currentActorID: currentActorID,
                            viewModel: viewModel,
                            refreshSessionsFromBackend: refreshSessionsFromBackend,
                            navigationPath: $sessionsPath,
                            connectedAgentsStore: connectedAgentsStore,
                            onReconnect: onReconnect)
            }
            Tab("Tasks", systemImage: "checklist", value: AppTab.tasks) {
                TasksTab(mqtt: mqtt,
                         pairing: pairing,
                         teamclawService: teamclawService,
                         activeTeam: activeTeam,
                         sessionViewModel: viewModel,
                         connectedAgentsStore: connectedAgentsStore,
                         onReconnect: onReconnect)
            }
            Tab("Actors", systemImage: "person.2", value: AppTab.members) {
                if let actorStore {
                    MembersTab(pairing: pairing,
                               mqtt: mqtt,
                               sessionViewModel: viewModel,
                               teamclawService: teamclawService,
                               activeTeam: activeTeam,
                               store: actorStore,
                               connectedAgentsStore: connectedAgentsStore,
                               onReconnect: onReconnect)
                } else {
                    ContentUnavailableView("No Team Selected",
                                          systemImage: "person.2",
                                          description: Text("Create or join a team to see actors."))
                }
            }
            Tab(value: AppTab.search, role: .search) {
                SearchTab(mqtt: mqtt,
                          pairing: pairing,
                          teamclawService: teamclawService,
                          viewModel: viewModel,
                          rootSelection: $selection,
                          sessionsPath: $sessionsPath)
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .overlay(alignment: .top) {
            ConnectionBannerOverlay(mqtt: mqtt, onReconnect: onReconnect)
        }
        .task {
            viewModel.start(mqtt: mqtt, deviceId: pairing.deviceId, modelContext: modelContext, teamclawService: teamclawService)
        }
        .task(id: activeTeam?.id) {
            await configureStores()
        }
        .onReceive(NotificationCenter.default.publisher(for: .amuxInviteTokenReceived)) { note in
            guard let token = note.userInfo?["token"] as? String,
                  let store = actorStore else { return }
            Task { _ = await store.claimInvite(token: token) }
        }
    }

    @MainActor
    private func configureStores() async {
        guard let activeTeam else {
            actorStore = nil
            connectedAgentsStore = nil
            sessionIDsRepo = nil
            sessionsRepo = nil
            viewModel.validSessionIDs = nil
            return
        }
        if actorStore == nil {
            if let repo = try? SupabaseActorRepository() {
                let store = ActorStore(teamID: activeTeam.id,
                                       repository: repo,
                                       modelContext: modelContext)
                actorStore = store
                // Populate CachedActor eagerly so pickers opened from any tab
                // (New Session collaborators, session detail members, etc.)
                // have rows to show without needing to visit the Actors tab
                // first.
                await store.reload()
            }
        }
        if connectedAgentsStore == nil {
            if let repo = try? SupabaseAgentAccessRepository() {
                let store = ConnectedAgentsStore(teamID: activeTeam.id, repository: repo)
                connectedAgentsStore = store
                await store.reload()
            }
        }
        if sessionIDsRepo == nil {
            sessionIDsRepo = try? SupabaseSessionIDsRepository()
        }
        if sessionsRepo == nil {
            sessionsRepo = try? SupabaseSessionsRepository()
        }
        await refreshSessionsFromBackend()
    }

    @MainActor
    private func refreshSessionsFromBackend() async {
        guard let activeTeam else { return }

        if let repo = sessionsRepo,
           let records = try? await repo.listSessions(teamID: activeTeam.id) {
            viewModel.syncSessionRecords(records, modelContext: modelContext)
            return
        }

        if let repo = sessionIDsRepo,
           let ids = try? await repo.listSessionIDs(teamID: activeTeam.id) {
            viewModel.validSessionIDs = ids
            viewModel.reloadSessions(modelContext: modelContext)
        }
    }
}
