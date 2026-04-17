import SwiftUI
import AMUXCore

public struct SettingsScene: Scene {
    let pairing: PairingManager

    public init(pairing: PairingManager) {
        self.pairing = pairing
    }

    public var body: some Scene {
        Settings {
            TabView {
                GeneralPreferencesView()
                    .tabItem { Label("General", systemImage: "gearshape") }

                AccountPreferencesView(pairing: pairing)
                    .tabItem { Label("Account", systemImage: "person.crop.circle") }
            }
            .frame(minWidth: 460, minHeight: 320)
        }
    }
}

