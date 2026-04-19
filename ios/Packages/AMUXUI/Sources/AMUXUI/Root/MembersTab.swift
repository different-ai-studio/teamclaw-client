import SwiftUI
import AMUXCore

public struct MembersTab: View {
    let mqtt: MQTTService
    let pairing: PairingManager
    let connectionMonitor: ConnectionMonitor
    let sessionViewModel: SessionListViewModel

    @State private var showSettings = false

    public init(mqtt: MQTTService,
                pairing: PairingManager,
                connectionMonitor: ConnectionMonitor,
                sessionViewModel: SessionListViewModel) {
        self.mqtt = mqtt
        self.pairing = pairing
        self.connectionMonitor = connectionMonitor
        self.sessionViewModel = sessionViewModel
    }

    public var body: some View {
        NavigationStack {
            MemberListContent(mqtt: mqtt,
                              deviceId: pairing.deviceId,
                              peerId: "ios-\(pairing.authToken.prefix(6))")
                .navigationTitle("Members")
                .navigationBarTitleDisplayMode(.large)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button { showSettings = true } label: {
                            Image(systemName: "gearshape").font(.title3).foregroundStyle(.primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .sheet(isPresented: $showSettings) {
                    SettingsView(pairing: pairing,
                                 connectionMonitor: connectionMonitor,
                                 mqtt: mqtt,
                                 sessionViewModel: sessionViewModel)
                }
        }
    }
}
