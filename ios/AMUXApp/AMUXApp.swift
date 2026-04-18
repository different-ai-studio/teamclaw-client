import SwiftUI
import SwiftData
import AMUXCore
import Sentry

@main
struct AMUXApp: App {
    @State private var pairing = PairingManager()
    let modelContainer: ModelContainer

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

        // Explicit VersionedSchema + migration plan so SwiftData never falls
        // back to destructive migration on a field-shape change. See
        // AMUXSchema.swift for the upgrade checklist when models evolve.
        do {
            let schema = Schema(versionedSchema: AMUXSchemaV1.self)
            let config = ModelConfiguration(schema: schema)
            modelContainer = try ModelContainer(
                for: schema,
                migrationPlan: AMUXMigrationPlan.self,
                configurations: config
            )
        } catch {
            fatalError("Failed to initialise ModelContainer: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView(pairing: pairing)
        }
        .modelContainer(modelContainer)
    }
}
