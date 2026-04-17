import SwiftUI
import AMUXCore

public struct RootView: View {
    @State private var pairing: PairingManager

    public init(pairing: PairingManager) {
        _pairing = State(initialValue: pairing)
    }

    public var body: some View {
        Group {
            if pairing.isPaired {
                MainWindowView(pairing: pairing)
            } else {
                PairingView(pairing: pairing)
            }
        }
    }
}
