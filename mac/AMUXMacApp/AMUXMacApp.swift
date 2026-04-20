import SwiftUI
import SwiftData
import AMUXCore
import AMUXMacUI

@main
struct AMUXMacApp: App {
    @State private var pairing = PairingManager(store: KeychainCredentialStore())
    @State private var detailTeamclaw = TeamclawService()
    @State private var shared = SharedConnection()
    @AppStorage(AppAppearance.storageKey) private var appearanceRaw: String = AppAppearance.system.rawValue
    @State private var notificationsReady = false

    var body: some Scene {
        WindowGroup {
            RootView(pairing: pairing, teamclaw: detailTeamclaw)
                .frame(minWidth: 1100, minHeight: 700)
                .preferredColorScheme(currentAppearance.colorScheme)
                .environment(shared)
                .task {
                    guard !notificationsReady else { return }
                    await PermissionNotificationCenter.shared.bootstrap()
                    PermissionNotificationCenter.shared.onFocusSession = { sid in
                        NSApp.activate(ignoringOtherApps: true)
                        _ = sid
                    }
                    notificationsReady = true
                }
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
            .environment(shared)

        TaskEditorWindowScene(teamclawService: detailTeamclaw)

        MembersWindowScene(pairing: pairing)
            .environment(shared)

        InviteWindowScene(pairing: pairing)
            .environment(shared)

        SettingsScene(pairing: pairing)
    }

    private var currentAppearance: AppAppearance {
        AppAppearance(rawValue: appearanceRaw) ?? .system
    }
}
