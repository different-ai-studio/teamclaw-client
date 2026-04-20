import SwiftUI
import SwiftData
import AMUXCore
import AMUXMacUI
import Sentry

@main
struct AMUXMacApp: App {
    @State private var pairing = PairingManager(store: KeychainCredentialStore())
    @State private var detailTeamclaw = TeamclawService()
    @State private var shared = SharedConnection()
    @State private var notificationsReady = false
    let modelContainer: ModelContainer

    init() {
        SentrySDK.start { options in
            options.dsn = "https://7551f3236520b84b27ec473a1d7c1480@o60909.ingest.us.sentry.io/4511233545011200"
            options.tracesSampleRate = 0.2
            options.enableAutoPerformanceTracing = true
            options.enableSwizzling = true
            #if DEBUG
            options.debug = true
            options.environment = "development"
            #else
            options.environment = "production"
            #endif
        }

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

        TaskEditorWindowScene(teamclawService: detailTeamclaw)
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
