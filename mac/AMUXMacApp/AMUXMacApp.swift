import SwiftUI
import SwiftData
import AMUXCore
import AMUXMacUI

@main
struct AMUXMacApp: App {
    @State private var pairing = PairingManager(store: KeychainCredentialStore())
    @State private var detailTeamclaw = TeamclawService()

    var body: some Scene {
        WindowGroup {
            RootView(pairing: pairing, teamclaw: detailTeamclaw)
                .frame(minWidth: 1100, minHeight: 700)
        }
        .windowResizability(.contentMinSize)
        .modelContainer(for: [
            Member.self,
            CollabSession.self,
            SessionMessage.self,
            WorkItem.self,
        ])

        DetailWindowScene(pairing: pairing, teamclawService: detailTeamclaw)
    }
}
