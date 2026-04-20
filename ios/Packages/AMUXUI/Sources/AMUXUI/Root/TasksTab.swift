import SwiftUI
import SwiftData
import AMUXCore

public struct TasksTab: View {
    let pairing: PairingManager
    let connectionMonitor: ConnectionMonitor
    let teamclawService: TeamclawService?
    let mqtt: MQTTService
    let sessionViewModel: SessionListViewModel

    @Environment(\.modelContext) private var modelContext

    @State private var showSettings = false
    @State private var showCreate = false
    @State private var navigationPath: [String] = []

    public init(mqtt: MQTTService,
                pairing: PairingManager,
                connectionMonitor: ConnectionMonitor,
                teamclawService: TeamclawService?,
                sessionViewModel: SessionListViewModel) {
        self.mqtt = mqtt
        self.pairing = pairing
        self.connectionMonitor = connectionMonitor
        self.teamclawService = teamclawService
        self.sessionViewModel = sessionViewModel
    }

    public var body: some View {
        NavigationStack(path: $navigationPath) {
            TaskListView(pairing: pairing,
                         connectionMonitor: connectionMonitor,
                         teamclawService: teamclawService,
                         showCreate: $showCreate)
                .navigationTitle("Tasks")
                .navigationBarTitleDisplayMode(.large)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button { showSettings = true } label: {
                            Image(systemName: "gearshape").font(.title3).foregroundStyle(.primary)
                        }
                        .buttonStyle(.plain)
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button { showCreate = true } label: {
                            Image(systemName: "plus").font(.title3).foregroundStyle(.primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .sheet(isPresented: $showSettings) {
                    SettingsView(pairing: pairing,
                                 connectionMonitor: connectionMonitor,
                                 mqtt: mqtt,
                                 sessionViewModel: sessionViewModel)
                }
                .navigationDestination(for: String.self) { id in
                    if id.hasPrefix("task:") {
                        let taskId = String(id.dropFirst("task:".count))
                        let descriptor = FetchDescriptor<SessionTask>(
                            predicate: #Predicate { $0.taskId == taskId }
                        )
                        if let item = (try? modelContext.fetch(descriptor))?.first {
                            TaskDetailView(item: item,
                                           sessionViewModel: sessionViewModel,
                                           teamclawService: teamclawService,
                                           mqtt: mqtt,
                                           deviceId: pairing.deviceId,
                                           peerId: "ios-\(pairing.authToken.prefix(6))",
                                           navigationPath: $navigationPath)
                        } else {
                            Text("Task not found")
                        }
                    } else if id.hasPrefix("collab:") {
                        let sessionId = String(id.dropFirst("collab:".count))
                        let descriptor = FetchDescriptor<Session>(
                            predicate: #Predicate { $0.sessionId == sessionId }
                        )
                        if let session = (try? modelContext.fetch(descriptor))?.first {
                            AgentDetailView(session: session, mqtt: mqtt,
                                            deviceId: pairing.deviceId,
                                            peerId: "ios-\(pairing.authToken.prefix(6))",
                                            teamclawService: teamclawService,
                                            navigationPath: $navigationPath)
                        } else {
                            Text("Session not found")
                        }
                    } else if let agent = sessionViewModel.agents.first(where: { $0.agentId == id }) {
                        AgentDetailView(agent: agent, mqtt: mqtt,
                                        deviceId: pairing.deviceId,
                                        peerId: "ios-\(pairing.authToken.prefix(6))",
                                        allAgentIds: sessionViewModel.agents.map(\.agentId),
                                        navigationPath: $navigationPath)
                    } else {
                        Text("Agent not found")
                    }
                }
        }
    }
}
