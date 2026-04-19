import SwiftUI
import AMUXCore

public struct RootTabView: View {
    let mqtt: MQTTService
    let pairing: PairingManager
    let connectionMonitor: ConnectionMonitor
    let teamclawService: TeamclawService?
    var onReconnect: (() -> Void)?

    @Environment(\.modelContext) private var modelContext
    @State private var viewModel = SessionListViewModel()
    @SceneStorage("rootTab") private var selection: AppTab = .sessions
    @State private var sessionsPath: [String] = []

    public init(mqtt: MQTTService,
                pairing: PairingManager,
                connectionMonitor: ConnectionMonitor,
                teamclawService: TeamclawService?,
                onReconnect: (() -> Void)? = nil) {
        self.mqtt = mqtt
        self.pairing = pairing
        self.connectionMonitor = connectionMonitor
        self.teamclawService = teamclawService
        self.onReconnect = onReconnect
    }

    public var body: some View {
        TabView(selection: $selection) {
            Tab("Sessions", systemImage: "bubble.left.and.bubble.right", value: AppTab.sessions) {
                SessionsTab(mqtt: mqtt,
                            pairing: pairing,
                            connectionMonitor: connectionMonitor,
                            teamclawService: teamclawService,
                            viewModel: viewModel,
                            navigationPath: $sessionsPath)
            }
            Tab("Tasks", systemImage: "checklist", value: AppTab.tasks) {
                TasksTab(mqtt: mqtt,
                         pairing: pairing,
                         connectionMonitor: connectionMonitor,
                         teamclawService: teamclawService,
                         sessionViewModel: viewModel)
            }
            Tab("Members", systemImage: "person.2", value: AppTab.members) {
                MembersTab(mqtt: mqtt,
                           pairing: pairing,
                           connectionMonitor: connectionMonitor,
                           sessionViewModel: viewModel)
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
                                    connectionMonitor: connectionMonitor,
                                    onReconnect: onReconnect)
        }
        .task {
            viewModel.start(mqtt: mqtt, deviceId: pairing.deviceId, modelContext: modelContext)
        }
    }
}
