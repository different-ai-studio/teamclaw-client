import SwiftUI
import AMUXCore

public struct RootView: View {
    let pairing: PairingManager
    let teamclaw: TeamclawService

    public init(pairing: PairingManager, teamclaw: TeamclawService) {
        self.pairing = pairing
        self.teamclaw = teamclaw
    }

    public var body: some View {
        if pairing.isPaired {
            MainWindowView(pairing: pairing, teamclaw: teamclaw)
        } else {
            PairingView(pairing: pairing)
        }
    }
}
