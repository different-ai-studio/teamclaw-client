import SwiftUI
import AMUXCore

public struct MainWindowView: View {
    let pairing: PairingManager
    @State private var sidebarSelection: SidebarItem? = .sessions
    @State private var listSelection: String?
    @State private var mqtt: MQTTService?
    @State private var monitor: ConnectionMonitor?

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
        .navigationSplitViewColumnWidth(min: 220, ideal: 230, max: 320)
    }

    private var sidebar: some View {
        List(selection: $sidebarSelection) {
            Section("功能") {
                Label("Sessions", systemImage: "bubble.left.and.bubble.right")
                    .tag(SidebarItem.sessions)
                Label("Tasks", systemImage: "checkmark.circle")
                    .tag(SidebarItem.tasks)
            }
            Section("Members") {
                Text("(no members yet)")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 220, ideal: 230, max: 320)
    }

    private var list: some View {
        VStack {
            Spacer()
            Text(sidebarSelection?.title ?? "—")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("List column placeholder")
                .font(.callout)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(minWidth: 320)
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
    }
}

public enum SidebarItem: Hashable {
    case sessions
    case tasks

    var title: String {
        switch self {
        case .sessions: "Sessions"
        case .tasks: "Tasks"
        }
    }
}
