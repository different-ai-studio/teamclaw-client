import SwiftUI
import SwiftData
import AMUXCore

@main
struct AMUXApp: App {
    @State private var pairing = PairingManager()

    var body: some Scene {
        WindowGroup {
            ContentView(pairing: pairing)
        }
        .modelContainer(for: [Agent.self, AgentEvent.self, Member.self, Workspace.self, CollabSession.self, SessionMessage.self, WorkItem.self])
    }
}
