import SwiftUI
import SwiftData
import AMUXCore

public struct MainWindowView: View {
    let pairing: PairingManager
    @Environment(\.modelContext) private var modelContext
    @SceneStorage("amux.mainWindow.sidebar") private var sidebarStorage: String = "function:sessions"
    @SceneStorage("amux.mainWindow.selectedSession") private var selectedSessionId: String?
    @SceneStorage("amux.mainWindow.selectedTask") private var selectedTaskId: String?
    @State private var mqtt: MQTTService?
    @State private var monitor: ConnectionMonitor?
    @State private var peerId: String = "mac-\(UUID().uuidString.prefix(6))"
    @State private var showNewSession = false
    let teamclaw: TeamclawService
    @State private var members = MemberListViewModel()

    private static let teamId = "teamclaw"

    public init(pairing: PairingManager, teamclaw: TeamclawService) {
        self.pairing = pairing
        self.teamclaw = teamclaw
    }

    private var sidebarSelection: SidebarItem? {
        Self.parseSidebar(sidebarStorage)
    }

    private static func parseSidebar(_ raw: String) -> SidebarItem? {
        if raw == "function:sessions" { return .function(.sessions) }
        if raw == "function:tasks" { return .function(.tasks) }
        if raw.hasPrefix("member:") {
            return .member(memberId: String(raw.dropFirst("member:".count)))
        }
        return .function(.sessions)
    }

    private static func encodeSidebar(_ item: SidebarItem?) -> String {
        switch item {
        case .function(.sessions), .none: "function:sessions"
        case .function(.tasks): "function:tasks"
        case .member(let id): "member:\(id)"
        }
    }

    public var body: some View {
        NavigationSplitView {
            sidebar
        } content: {
            list
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
        .sheet(isPresented: $showNewSession) {
            if let mqtt {
                NewSessionSheet(
                    mqtt: mqtt,
                    deviceId: pairing.deviceId,
                    peerId: peerId,
                    onSessionCreated: { agentId in
                        selectedSessionId = agentId
                    }
                )
            } else {
                VStack(spacing: 12) {
                    Text("Not connected")
                        .font(.headline)
                    Text("Connect to the daemon before creating a session.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Button("Close") { showNewSession = false }
                }
                .padding(32)
                .frame(minWidth: 320)
            }
        }
    }

    private var sidebar: some View {
        SidebarView(selection: sidebarSelectionBinding, members: members.members)
            .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 320)
    }

    private var sidebarSelectionBinding: Binding<SidebarItem?> {
        Binding(
            get: { sidebarSelection },
            set: { newValue in sidebarStorage = Self.encodeSidebar(newValue) }
        )
    }

    private var list: some View {
        Group {
            switch sidebarSelection {
            case .function(.tasks):
                TaskListColumn(selectedTaskId: $selectedTaskId)
            case .function(.sessions), .none:
                SessionListColumn(
                    memberFilter: nil,
                    memberName: nil,
                    selectedSessionId: $selectedSessionId,
                    onNewSession: handleNewSession
                )
            case .member(let id):
                SessionListColumn(
                    memberFilter: id,
                    memberName: members.members.first(where: { $0.memberId == id })?.displayName,
                    selectedSessionId: $selectedSessionId,
                    onNewSession: handleNewSession
                )
            }
        }
        .navigationSplitViewColumnWidth(min: 280, ideal: 360, max: 480)
    }

    private func handleNewSession() {
        showNewSession = true
    }

    private var detail: some View {
        DetailPlaceholderView(
            pairing: pairing,
            monitor: monitor,
            teamclawService: teamclaw,
            actorId: pairing.deviceId,
            selectedSessionId: selectedSessionId,
            selectedTaskId: selectedTaskId
        )
        .frame(minWidth: 480)
        .task { await connectIfNeeded() }
    }

    private func connectIfNeeded() async {
        guard mqtt == nil, pairing.isPaired else { return }
        let service = MQTTService()
        do {
            try await service.connect(
                host: pairing.brokerHost,
                port: pairing.brokerPort,
                username: pairing.username,
                password: pairing.password,
                clientId: "amux-mac-\(UUID().uuidString.prefix(6))",
                useTLS: pairing.useTLS
            )
        } catch {
            return
        }
        let mon = ConnectionMonitor()
        mon.start(mqtt: service, deviceId: pairing.deviceId)
        self.mqtt = service
        self.monitor = mon

        // Start data sync (peerId persisted on the view's state so the
        // NewSessionSheet can publish commands with the same peer identity).
        teamclaw.start(
            mqtt: service,
            teamId: Self.teamId,
            deviceId: pairing.deviceId,
            peerId: peerId,
            modelContext: modelContext
        )
        await MainActor.run {
            members.start(mqtt: service, deviceId: pairing.deviceId, modelContext: modelContext)
        }
    }
}
