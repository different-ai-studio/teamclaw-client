import SwiftUI
import AMUXCore

public struct MembersTab: View {
    let pairing: PairingManager
    let connectionMonitor: ConnectionMonitor
    let mqtt: MQTTService
    let sessionViewModel: SessionListViewModel
    let activeTeam: TeamSummary?
    let store: ActorStore

    @State private var showSettings = false
    @State private var showInvite   = false

    public init(pairing: PairingManager,
                connectionMonitor: ConnectionMonitor,
                mqtt: MQTTService,
                sessionViewModel: SessionListViewModel,
                activeTeam: TeamSummary?,
                store: ActorStore) {
        self.pairing = pairing
        self.connectionMonitor = connectionMonitor
        self.mqtt = mqtt
        self.sessionViewModel = sessionViewModel
        self.activeTeam = activeTeam
        self.store = store
    }

    public var body: some View {
        NavigationStack {
            MemberListContent(store: store)
                .navigationTitle("Actors")
                .navigationBarTitleDisplayMode(.large)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button { showSettings = true } label: {
                            Image(systemName: "gearshape").font(.title3).foregroundStyle(.primary)
                        }.buttonStyle(.plain)
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button { showInvite = true } label: {
                            Image(systemName: "person.badge.plus").font(.title3)
                        }
                        .buttonStyle(.plain)
                        .disabled(activeTeam == nil)
                        .opacity(activeTeam == nil ? 0.4 : 1)
                    }
                }
                .sheet(isPresented: $showSettings) {
                    SettingsView(pairing: pairing,
                                 connectionMonitor: connectionMonitor,
                                 mqtt: mqtt,
                                 sessionViewModel: sessionViewModel)
                }
                .sheet(isPresented: $showInvite) {
                    MemberInviteSheet(store: store)
                }
        }
    }
}
