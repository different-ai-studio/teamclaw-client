import SwiftUI
import SwiftData
import AMUXCore
import Sentry

@main
struct AMUXApp: App {
    @State private var pairing = PairingManager()

    init() {
        SentrySDK.start { options in
            options.dsn = "https://7551f3236520b84b27ec473a1d7c1480@o60909.ingest.us.sentry.io/4511233545011200"
            options.tracesSampleRate = 0.2
            options.enableAutoPerformanceTracing = true
            options.enableUIViewControllerTracing = true
            options.enableSwizzling = true
            options.attachScreenshot = true
            options.attachViewHierarchy = true
            #if DEBUG
            options.debug = true
            options.environment = "development"
            #else
            options.environment = "production"
            #endif
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView(pairing: pairing)
        }
        .modelContainer(for: [Agent.self, AgentEvent.self, Member.self, Workspace.self, CollabSession.self, SessionMessage.self, WorkItem.self])
    }
}
