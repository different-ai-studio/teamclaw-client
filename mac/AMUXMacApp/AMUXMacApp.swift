import SwiftUI
import SwiftData
import AMUXCore
import AMUXMacUI

@main
struct AMUXMacApp: App {
    @State private var pairing = PairingManager(store: KeychainCredentialStore())

    var body: some Scene {
        WindowGroup {
            RootView(pairing: pairing)
                .frame(minWidth: 1100, minHeight: 700)
        }
        .windowResizability(.contentMinSize)
        .modelContainer(for: [
            Member.self,
            CollabSession.self,
            SessionMessage.self,
            WorkItem.self,
        ])
    }
}
