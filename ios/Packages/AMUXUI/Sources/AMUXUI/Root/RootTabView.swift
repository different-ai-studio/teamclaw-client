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
    @Environment(AppOnboardingCoordinator.self) private var coordinator: AppOnboardingCoordinator?
    @State private var viewModel = SessionListViewModel()
    @SceneStorage("rootTab") private var selection: AppTab = .sessions
    @State private var sessionsPath: [String] = []
    @State private var actorStore: ActorStore?
    @State private var connectedAgentsStore: ConnectedAgentsStore?
    @State private var sessionIDsRepo: SupabaseSessionIDsRepository?
    @State private var sessionsRepo: SupabaseSessionsRepository?
    @State private var agentRuntimesRepo: SupabaseAgentRuntimesRepository?
    @State private var workspacesRepo: SupabaseWorkspaceRepository?
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
                            onSignOut: onSignOut)
            }
            Tab(IdeaUIPresentation.pluralTitle, systemImage: IdeaUIPresentation.systemImage, value: AppTab.ideas) {
                IdeasTab(mqtt: mqtt,
                         pairing: pairing,
                         teamclawService: teamclawService,
                         activeTeam: activeTeam,
                         sessionViewModel: viewModel,
                         connectedAgentsStore: connectedAgentsStore)
            }
            Tab("Actors", systemImage: "person.2", value: AppTab.members) {
                if let actorStore {
                    MembersTab(pairing: pairing,
                               mqtt: mqtt,
                               sessionViewModel: viewModel,
                               teamclawService: teamclawService,
                               activeTeam: activeTeam,
                               currentActorID: currentActorID,
                               store: actorStore,
                               connectedAgentsStore: connectedAgentsStore,
                               showInvite: $showInviteAfterReminder)
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
            // SessionListVM observes ConnectedAgentsStore directly and fans
            // its `runtime/+/state` subscriptions out per known daemon, so we
            // start it after configureStores so the initial agent set is
            // already loaded.
            viewModel.start(
                mqtt: mqtt,
                teamID: activeTeam?.id ?? "",
                connectedAgentsStore: connectedAgentsStore,
                modelContext: modelContext,
                teamclawService: teamclawService
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: .amuxInviteTokenReceived)) { note in
            guard let token = note.userInfo?["token"] as? String,
                  let store = actorStore else { return }
            Task { await claimAndSwitch(token: token, store: store) }
        }
        .onChange(of: actorStore != nil) { _, ready in
            // Replay a token captured by ChooseAuthView (pre-auth) once the
            // post-auth ActorStore is alive — without it the existing
            // notification path doesn't fire (ChooseAuthView posts the token
            // before this view is mounted).
            if ready { replayPendingInviteIfNeeded() }
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
        // TeamclawService needs ConnectedAgentsStore to fan its per-daemon
        // notify+rpcRes subscriptions out, so kick it off here (after the
        // store has loaded) instead of in ContentView. start() is idempotent
        // — listenerTask?.cancel() handles re-entry on team changes.
        if let teamclawService {
            teamclawService.start(
                mqtt: mqtt,
                teamId: activeTeam.id,
                peerId: "ios-\(pairing.authToken.prefix(6))",
                modelContext: modelContext,
                connectedAgentsStore: connectedAgentsStore,
                currentActorID: currentActorID
            )
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
        if agentRuntimesRepo == nil {
            agentRuntimesRepo = try? SupabaseAgentRuntimesRepository()
        }
        if workspacesRepo == nil {
            workspacesRepo = try? SupabaseWorkspaceRepository()
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

    private func replayPendingInviteIfNeeded() {
        guard let coordinator,
              let token = coordinator.pendingInviteToken,
              !token.isEmpty,
              let store = actorStore else { return }
        // Clear first so a transient store re-creation can't trigger a second
        // claim against the same token.
        coordinator.pendingInviteToken = nil
        Task { await claimAndSwitch(token: token, store: store) }
    }

    /// Single entry point used by every flow that ends in a claim:
    ///   - the `amux://invite?token=…` deeplink (NotificationCenter)
    ///   - the pre-auth paste path on ChooseAuthView (`pendingInviteToken`)
    ///
    /// On success we re-bootstrap with `preferringTeamID:` so the active
    /// team — and everything that derives from it (settings team name, MQTT
    /// scope, ActorStore's queries) — flips to the team the user actually
    /// joined instead of staying pinned to whatever team was active when
    /// the claim fired.
    private func claimAndSwitch(token: String, store: ActorStore) async {
        guard let result = await store.claimInvite(token: token) else { return }
        // The same team — no switch needed; ActorStore.reload() already ran
        // inside claimInvite and the active context is correct.
        if let activeID = activeTeam?.id, activeID == result.teamID { return }
        await coordinator?.bootstrap(preferringTeamID: result.teamID)
    }

    @MainActor
    private func refreshSessionsFromBackend() async {
        guard let activeTeam else { return }

        let teamID = activeTeam.id
        let runtimesRepoLocal = agentRuntimesRepo
        let workspacesRepoLocal = workspacesRepo
        let sessionsRepoLocal = sessionsRepo
        let sessionIDsRepoLocal = sessionIDsRepo

        async let runtimesTask: [AgentRuntimeRecord]? = {
            guard let repo = runtimesRepoLocal else { return nil }
            return try? await repo.listForTeam(teamID: teamID)
        }()
        async let workspacesTask: [WorkspaceRecord]? = {
            guard let repo = workspacesRepoLocal else { return nil }
            return try? await repo.listWorkspaces(teamID: teamID, agentID: nil)
        }()

        if let repo = sessionsRepoLocal,
           let records = try? await repo.listSessions(teamID: teamID) {
            viewModel.syncSessionRecords(records, modelContext: modelContext)
        } else if let repo = sessionIDsRepoLocal,
                  let ids = try? await repo.listSessionIDs(teamID: teamID) {
            viewModel.validSessionIDs = ids
            viewModel.reloadSessions(modelContext: modelContext)
        }

        if let runtimes = await runtimesTask {
            viewModel.syncAgentRuntimeRecords(runtimes, modelContext: modelContext)
        }
        if let workspaces = await workspacesTask {
            viewModel.syncWorkspaceRecords(workspaces, modelContext: modelContext)
        }
    }
}
