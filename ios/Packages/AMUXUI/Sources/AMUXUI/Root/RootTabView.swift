import SwiftUI
import AMUXCore

public struct RootTabView: View {
    let mqtt: MQTTService
    let pairing: PairingManager
    let connectionMonitor: ConnectionMonitor
    let teamclawService: TeamclawService?
    let activeTeam: TeamSummary?
    let currentActorID: String?
    var onReconnect: (() -> Void)?

    @Environment(\.modelContext) private var modelContext
    @State private var viewModel = SessionListViewModel()
    @SceneStorage("rootTab") private var selection: AppTab = .sessions
    @State private var sessionsPath: [String] = []
    @State private var actorStore: ActorStore?

    public init(mqtt: MQTTService,
                pairing: PairingManager,
                connectionMonitor: ConnectionMonitor,
                teamclawService: TeamclawService?,
                activeTeam: TeamSummary? = nil,
                currentActorID: String? = nil,
                onReconnect: (() -> Void)? = nil) {
        self.mqtt = mqtt
        self.pairing = pairing
        self.connectionMonitor = connectionMonitor
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
                            connectionMonitor: connectionMonitor,
                            teamclawService: teamclawService,
                            activeTeam: activeTeam,
                            currentActorID: currentActorID,
                            viewModel: viewModel,
                            navigationPath: $sessionsPath)
            }
            Tab("Tasks", systemImage: "checklist", value: AppTab.tasks) {
                TasksTab(mqtt: mqtt,
                         pairing: pairing,
                         connectionMonitor: connectionMonitor,
                         teamclawService: teamclawService,
                         activeTeam: activeTeam,
                         sessionViewModel: viewModel)
            }
            Tab("Actors", systemImage: "person.2", value: AppTab.members) {
                if let actorStore {
                    MembersTab(pairing: pairing,
                               connectionMonitor: connectionMonitor,
                               mqtt: mqtt,
                               sessionViewModel: viewModel,
                               activeTeam: activeTeam,
                               store: actorStore)
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
            ConnectionBannerOverlay(mqtt: mqtt,
                                    pairing: pairing,
                                    connectionMonitor: connectionMonitor,
                                    onReconnect: onReconnect)
        }
        .task {
            viewModel.start(mqtt: mqtt, deviceId: pairing.deviceId, modelContext: modelContext)
        }
        .task(id: activeTeam?.id) {
            await configureActorStore()
        }
        .onReceive(NotificationCenter.default.publisher(for: .amuxInviteTokenReceived)) { note in
            guard let token = note.userInfo?["token"] as? String,
                  let store = actorStore else { return }
            Task { _ = await store.claimInvite(token: token) }
        }
    }

    @MainActor
    private func configureActorStore() async {
        guard let activeTeam else {
            actorStore = nil
            return
        }
        if actorStore == nil {
            if let repo = try? SupabaseActorRepository() {
                actorStore = ActorStore(teamID: activeTeam.id,
                                       repository: repo,
                                       modelContext: modelContext)
            }
        }
    }
}
