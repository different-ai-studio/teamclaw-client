import SwiftUI
import SwiftData
import AMUXCore
import AMUXMacUI

@main
struct AMUXMacApp: App {
    @State private var pairing = PairingManager(store: KeychainCredentialStore())
    @State private var detailTeamclaw = TeamclawService()
    @AppStorage(AppAppearance.storageKey) private var appearanceRaw: String = AppAppearance.system.rawValue

    var body: some Scene {
        WindowGroup {
            RootView(pairing: pairing, teamclaw: detailTeamclaw)
                .frame(minWidth: 1100, minHeight: 700)
                .preferredColorScheme(currentAppearance.colorScheme)
        }
        .windowResizability(.contentMinSize)
        .windowStyle(.hiddenTitleBar)
        .modelContainer(for: [
            Agent.self,
            AgentEvent.self,
            Member.self,
            CollabSession.self,
            SessionMessage.self,
            WorkItem.self,
            Workspace.self,
        ])

        DetailWindowScene(pairing: pairing, teamclawService: detailTeamclaw)

        SettingsScene(pairing: pairing)
    }

    private var currentAppearance: AppAppearance {
        AppAppearance(rawValue: appearanceRaw) ?? .system
    }
}
