import SwiftUI
import SwiftData
import AMUXCore

public struct MainWindowView: View {
    let pairing: PairingManager
    @Environment(\.modelContext) private var modelContext
    @State private var sidebarSelection: SidebarItem? = .function(.sessions)
    @State private var listSelection: String?
    @State private var selectedSessionId: String?
    @State private var selectedTaskId: String?
    @State private var mqtt: MQTTService?
    @State private var monitor: ConnectionMonitor?
    @State private var teamclaw = TeamclawService()
    @State private var members = MemberListViewModel()

    private static let teamId = "teamclaw"

    public init(pairing: PairingManager) {
        self.pairing = pairing
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
    }

    private var sidebar: some View {
        SidebarView(selection: $sidebarSelection, members: members.members)
            .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 320)
    }

    private var list: some View {
        Group {
            switch sidebarSelection {
            case .function(.tasks):
                TaskListColumn(selectedTaskId: $selectedTaskId)
            case .function(.sessions), .none:
                SessionListColumn(
                    memberFilter: nil,
                    selectedSessionId: $selectedSessionId
                )
            case .member(let id):
                SessionListColumn(
                    memberFilter: id,
                    selectedSessionId: $selectedSessionId
                )
            }
        }
        .navigationSplitViewColumnWidth(min: 280, ideal: 360, max: 480)
    }

    private var detail: some View {
        VStack {
            Spacer()
            HStack(spacing: 8) {
                Circle()
                    .fill(monitor?.daemonOnline == true ? Color.green : Color.red)
                    .frame(width: 10, height: 10)
                Text(monitor?.daemonOnline == true ? "Daemon online" : "Daemon offline")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Text("\(pairing.brokerHost):\(pairing.brokerPort)  ·  \(pairing.deviceId)")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .padding(.top, 4)
            Spacer()
        }
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

        // Start data sync
        let peerId = "mac-\(UUID().uuidString.prefix(6))"
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
