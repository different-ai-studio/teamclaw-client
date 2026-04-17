import SwiftUI
import AMUXCore

public struct MainWindowView: View {
    let pairing: PairingManager
    @State private var sidebarSelection: SidebarItem? = .sessions
    @State private var listSelection: String?

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
            Text("Detail column placeholder")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("Connected to \(pairing.brokerHost):\(pairing.brokerPort) as \(pairing.deviceId)")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .padding(.top, 4)
            Spacer()
        }
        .frame(minWidth: 480)
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
