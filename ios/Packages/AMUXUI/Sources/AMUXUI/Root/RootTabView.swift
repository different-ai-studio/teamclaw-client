import SwiftUI
import AMUXCore

public struct RootTabView: View {
    let mqtt: MQTTService
    let pairing: PairingManager
    let teamclawService: TeamclawService?
    let activeTeam: TeamSummary?
    let currentActorID: String?
    var onReconnect: (() -> Void)?
    var onSignOut: (() -> Void)?

    @Environment(\.modelContext) private var modelContext
    @State private var viewModel = SessionListViewModel()
    @SceneStorage("rootTab") private var selection: AppTab = .sessions
    @State private var sessionsPath: [String] = []
    @State private var actorStore: ActorStore?
    @State private var connectedAgentsStore: ConnectedAgentsStore?
    @State private var sessionIDsRepo: SupabaseSessionIDsRepository?
    @State private var sessionsRepo: SupabaseSessionsRepository?
    @State private var agentAccessRepo: SupabaseAgentAccessRepository?

    /// Drives the "add the team's first agent" reminder. Set once per app
    /// launch when we observe a team with zero agents; soft-dismissible so it
    /// doesn't reappear after the user closes it.
    @State private var showFirstAgentReminder: Bool = false
    /// Set when the user taps "Add agent" in the reminder sheet. Triggers the
    /// existing MemberInviteSheet on the Actors tab after the reminder closes.
    @State private var showInviteAfterReminder: Bool = false
    /// Tracks teams we've already shown the reminder for in this app launch
    /// so re-entering the team doesn't keep nagging.
    @State private var remindedTeams: Set<String> = []

    public init(mqtt: MQTTService,
                pairing: PairingManager,
                teamclawService: TeamclawService?,
                activeTeam: TeamSummary? = nil,
                currentActorID: String? = nil,
                onReconnect: (() -> Void)? = nil,
                onSignOut: (() -> Void)? = nil) {
        self.mqtt = mqtt
        self.pairing = pairing
        self.teamclawService = teamclawService
        self.activeTeam = activeTeam
        self.currentActorID = currentActorID
        self.onReconnect = onReconnect
        self.onSignOut = onSignOut
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
                            actorStore: actorStore,
                            onReconnect: onReconnect,
                            onSignOut: onSignOut)
            }
            Tab("Tasks", systemImage: "checklist", value: AppTab.tasks) {
                TasksTab(mqtt: mqtt,
                         pairing: pairing,
                         teamclawService: teamclawService,
                         activeTeam: activeTeam,
                         sessionViewModel: viewModel,
                         connectedAgentsStore: connectedAgentsStore,
                         onReconnect: onReconnect,
                         onSignOut: onSignOut)
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
                               showInvite: $showInviteAfterReminder,
                               onReconnect: onReconnect,
                               onSignOut: onSignOut)
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
        .task(id: activeTeam?.id) {
            await configureStores()
            // SessionListVM needs both teamID and the daemon's device_id to
            // build runtime/+/state subscription paths. configureStores
            // populates pairing.deviceId from connectedAgentsStore on first
            // run, so start *after* it returns rather than racing it.
            viewModel.start(
                mqtt: mqtt,
                teamID: activeTeam?.id ?? "",
                deviceId: pairing.deviceId,
                modelContext: modelContext,
                teamclawService: teamclawService
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: .amuxInviteTokenReceived)) { note in
            guard let token = note.userInfo?["token"] as? String,
                  let store = actorStore else { return }
            Task { _ = await store.claimInvite(token: token) }
        }
        .sheet(isPresented: $showFirstAgentReminder) {
            ZeroAgentReminderSheet {
                // Switch to the Actors tab and present its existing
                // invite sheet on the next runloop tick. Doing the switch
                // here keeps the reminder copy short while sending the
                // user to the canonical invite UI.
                selection = .members
                showInviteAfterReminder = true
            }
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
        // Backfill `pairing.deviceId` from the resolved daemon row in Supabase.
        // Post-Phase-4 the pairing flow no longer captures the daemon's
        // device_id locally, but downstream subscribers (SessionListVM and
        // RuntimeDetailVM legacy fallback) still expect it on the pairing
        // manager. Stopgap until pairing.deviceId is split into
        // iOS-install-id vs. daemon-device-id and call sites are migrated to
        // resolve via ConnectedAgentsStore directly.
        if pairing.deviceId.isEmpty,
           let resolvedDeviceID = connectedAgentsStore?.agents.first?.deviceID,
           !resolvedDeviceID.isEmpty {
            try? pairing.updateDaemonDeviceID(resolvedDeviceID)
        }
        if agentAccessRepo == nil {
            agentAccessRepo = try? SupabaseAgentAccessRepository()
        }
        if sessionIDsRepo == nil {
            sessionIDsRepo = try? SupabaseSessionIDsRepository()
        }
        if sessionsRepo == nil {
            sessionsRepo = try? SupabaseSessionsRepository()
        }
        await refreshSessionsFromBackend()
        await maybeShowFirstAgentReminder(team: activeTeam)
    }

    /// Polls Supabase once per launch per team for the agent count and shows
    /// the reminder when the team is empty. Soft-dismissible — does not
    /// reappear after the user closes it within the same app launch.
    @MainActor
    private func maybeShowFirstAgentReminder(team: TeamSummary) async {
        guard !remindedTeams.contains(team.id), let repo = agentAccessRepo else { return }
        do {
            let count = try await repo.teamAgentCount(teamID: team.id)
            remindedTeams.insert(team.id)
            if count == 0 {
                showFirstAgentReminder = true
            }
        } catch {
            // Soft prompt; failure to count is not user-visible.
        }
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
