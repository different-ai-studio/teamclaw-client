import SwiftUI
import SwiftData
import AMUXCore

public struct SessionsTab: View {
    let mqtt: MQTTService
    let pairing: PairingManager
    let connectionMonitor: ConnectionMonitor
    let teamclawService: TeamclawService?
    @Bindable var viewModel: SessionListViewModel

    @Environment(\.modelContext) private var modelContext

    @State private var showSettings = false
    @State private var showNewSession = false
    @Binding var navigationPath: [String]

    @State private var isEditing = false
    @State private var selectedIDs: Set<String> = []

    @Namespace private var sheetTransition

    public init(mqtt: MQTTService,
                pairing: PairingManager,
                connectionMonitor: ConnectionMonitor,
                teamclawService: TeamclawService?,
                viewModel: SessionListViewModel,
                navigationPath: Binding<[String]>) {
        self.mqtt = mqtt
        self.pairing = pairing
        self.connectionMonitor = connectionMonitor
        self.teamclawService = teamclawService
        self.viewModel = viewModel
        self._navigationPath = navigationPath
    }

    public var body: some View {
        NavigationStack(path: $navigationPath) {
            SessionListContent(
                viewModel: viewModel,
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
                    .buttonStyle(.plain)
                    .matchedTransitionSource(id: "newSession", in: sheetTransition)
                }
            }
            .navigationDestination(for: String.self) { id in
                if id.hasPrefix("collab:") {
                    let sessionId = String(id.dropFirst("collab:".count))
                    let descriptor = FetchDescriptor<CollabSession>(
                        predicate: #Predicate { $0.sessionId == sessionId }
                    )
                    if let session = (try? modelContext.fetch(descriptor))?.first {
                        AgentDetailView(collabSession: session, mqtt: mqtt,
                                        deviceId: pairing.deviceId,
                                        peerId: "ios-\(pairing.authToken.prefix(6))",
                                        teamclawService: teamclawService,
                                        navigationPath: $navigationPath)
                    } else {
                        Text("Collab session not found")
                    }
                } else if let agent = viewModel.agents.first(where: { $0.agentId == id }) {
                    AgentDetailView(agent: agent, mqtt: mqtt,
                                    deviceId: pairing.deviceId,
                                    peerId: "ios-\(pairing.authToken.prefix(6))",
                                    allAgentIds: viewModel.agents.map(\.agentId),
                                    navigationPath: $navigationPath)
                } else {
                    Text("Agent not found")
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(pairing: pairing,
                             connectionMonitor: connectionMonitor,
                             mqtt: mqtt,
                             sessionViewModel: viewModel)
            }
            .sheet(isPresented: $showNewSession) {
                NewSessionSheet(mqtt: mqtt, deviceId: pairing.deviceId,
                               peerId: "ios-\(pairing.authToken.prefix(6))",
                               viewModel: viewModel) { agentId in
                    navigationPath.append(agentId)
                }
                .modifier(ZoomTransitionModifier(sourceID: "newSession", namespace: sheetTransition))
            }
            .task {
                viewModel.start(mqtt: mqtt, deviceId: pairing.deviceId, modelContext: modelContext)
            }
            .onChange(of: teamclawService?.sessions.count) {
                viewModel.reloadCollabSessions(modelContext: modelContext)
            }
        }
    }
}
