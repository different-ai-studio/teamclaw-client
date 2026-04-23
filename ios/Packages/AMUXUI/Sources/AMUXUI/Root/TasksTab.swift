import SwiftUI
import SwiftData
import AMUXCore

public struct TasksTab: View {
    let pairing: PairingManager
    let teamclawService: TeamclawService?
    let activeTeam: TeamSummary?
    let mqtt: MQTTService
    let sessionViewModel: SessionListViewModel
    let connectedAgentsStore: ConnectedAgentsStore?
    var onReconnect: (() -> Void)?

    @Environment(\.modelContext) private var modelContext

    @State private var showSettings = false
    @State private var showCreate = false
    @State private var navigationPath: [String] = []
    @State private var taskStore: TaskStore?
    @State private var taskStoreTeamID: String?
    @State private var taskSetupError: String?

    public init(
        mqtt: MQTTService,
        pairing: PairingManager,
        teamclawService: TeamclawService?,
        activeTeam: TeamSummary?,
        sessionViewModel: SessionListViewModel,
        connectedAgentsStore: ConnectedAgentsStore? = nil,
        onReconnect: (() -> Void)? = nil
    ) {
        self.mqtt = mqtt
        self.pairing = pairing
        self.teamclawService = teamclawService
        self.activeTeam = activeTeam
        self.sessionViewModel = sessionViewModel
        self.connectedAgentsStore = connectedAgentsStore
        self.onReconnect = onReconnect
    }

    public var body: some View {
        NavigationStack(path: $navigationPath) {
            content
                .navigationTitle("Tasks")
                .navigationBarTitleDisplayMode(.large)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button { showSettings = true } label: {
                            Image(systemName: "gearshape").font(.title3).foregroundStyle(.primary)
                        }
                        .buttonStyle(.plain)
                    }
                    if taskStore != nil {
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Button { showCreate = true } label: {
                                Image(systemName: "plus").font(.title3).foregroundStyle(.primary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .sheet(isPresented: $showSettings) {
                    SettingsView(pairing: pairing,
                                 connectedAgentsStore: connectedAgentsStore,
                                 activeTeam: activeTeam,
                                 onReconnect: onReconnect)
                }
                .navigationDestination(for: String.self) { id in
                    if id.hasPrefix("task:") {
                        let taskID = String(id.dropFirst("task:".count))
                        if let taskStore {
                            TaskDetailView(
                                taskID: taskID,
                                taskStore: taskStore,
                                sessionViewModel: sessionViewModel,
                                teamclawService: teamclawService,
                                mqtt: mqtt,
                                deviceId: pairing.deviceId,
                                peerId: "ios-\(pairing.authToken.prefix(6))",
                                navigationPath: $navigationPath
                            )
                        } else {
                            Text("Task store unavailable")
                        }
                    } else if id.hasPrefix("collab:") {
                        let sessionId = String(id.dropFirst("collab:".count))
                        let descriptor = FetchDescriptor<Session>(
                            predicate: #Predicate { $0.sessionId == sessionId }
                        )
                        if let session = (try? modelContext.fetch(descriptor))?.first {
                            if session.primaryAgentId == nil || !pairing.isPaired {
                                SessionView(session: session, teamclawService: teamclawService)
                            } else {
                                AgentDetailView(
                                    session: session,
                                    mqtt: mqtt,
                                    deviceId: pairing.deviceId,
                                    peerId: "ios-\(pairing.authToken.prefix(6))",
                                    teamclawService: teamclawService,
                                    navigationPath: $navigationPath,
                                    connectedAgentsStore: connectedAgentsStore
                                )
                            }
                        } else {
                            Text("Session not found")
                        }
                    } else if let agent = sessionViewModel.agents.first(where: { $0.agentId == id }) {
                        AgentDetailView(
                            agent: agent,
                            mqtt: mqtt,
                            deviceId: pairing.deviceId,
                            peerId: "ios-\(pairing.authToken.prefix(6))",
                            allAgentIds: sessionViewModel.agents.map(\.agentId),
                            navigationPath: $navigationPath,
                            connectedAgentsStore: connectedAgentsStore
                        )
                    } else {
                        Text("Agent not found")
                    }
                }
        }
        .task(id: activeTeam?.id) {
            await configureTaskStore()
        }
    }

    @ViewBuilder
    private var content: some View {
        if activeTeam == nil {
            ContentUnavailableView(
                "No Team Selected",
                systemImage: "person.3",
                description: Text("Create or join a team to manage tasks.")
            )
        } else if let taskSetupError {
            ContentUnavailableView(
                "Couldn’t Set Up Tasks",
                systemImage: "exclamationmark.triangle",
                description: Text(taskSetupError)
            )
        } else if let taskStore {
            TaskListView(taskStore: taskStore, showCreate: $showCreate)
        } else {
            ProgressView("Loading tasks…")
        }
    }

    @MainActor
    private func configureTaskStore() async {
        guard let activeTeam else {
            taskStore = nil
            taskStoreTeamID = nil
            taskSetupError = nil
            return
        }

        if taskStore == nil || taskStoreTeamID != activeTeam.id {
            do {
                let repository = try SupabaseTaskRepository()
                taskStore = TaskStore(
                    teamID: activeTeam.id,
                    repository: repository,
                    modelContext: modelContext
                )
                taskStoreTeamID = activeTeam.id
                taskSetupError = nil
            } catch {
                taskStore = nil
                taskStoreTeamID = nil
                taskSetupError = error.localizedDescription
                return
            }
        }

        await taskStore?.reload()
    }
}
