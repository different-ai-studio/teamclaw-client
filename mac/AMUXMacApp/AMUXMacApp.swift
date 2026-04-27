import SwiftUI
import SwiftData
import AMUXCore
import AMUXMacUI

@main
struct AMUXMacApp: App {
    @State private var pairing = PairingManager(store: KeychainCredentialStore())
    @State private var detailTeamclaw = TeamclawService()
    @State private var shared = SharedConnection()
    @State private var notificationsReady = false
    let modelContainer: ModelContainer

    init() {
        do {
            modelContainer = try AMUXModelContainerFactory.make()
        } catch {
            fatalError("Failed to initialise ModelContainer: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView(pairing: pairing, teamclaw: detailTeamclaw)
                .frame(minWidth: 1100, minHeight: 700)
                .appAppearance()
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
        .modelContainer(modelContainer)

        DetailWindowScene(pairing: pairing, teamclawService: detailTeamclaw)
            .environment(shared)
            .modelContainer(modelContainer)

        IdeaEditorWindowScene(teamclawService: detailTeamclaw)
            .modelContainer(modelContainer)

        MembersWindowScene(pairing: pairing)
            .environment(shared)
            .modelContainer(modelContainer)

        InviteWindowScene(pairing: pairing)
            .environment(shared)
            .modelContainer(modelContainer)

        SettingsScene(pairing: pairing)
    }
}
