import SwiftUI
import AMUXCore

public struct MembersTab: View {
    let pairing: PairingManager
    let mqtt: MQTTService
    let sessionViewModel: SessionListViewModel
    let teamclawService: TeamclawService?
    let activeTeam: TeamSummary?
    let store: ActorStore
    let connectedAgentsStore: ConnectedAgentsStore?
    var onReconnect: (() -> Void)?

    @State private var showSettings = false
    @State private var showInvite   = false

    public init(pairing: PairingManager,
                mqtt: MQTTService,
                sessionViewModel: SessionListViewModel,
                teamclawService: TeamclawService?,
                activeTeam: TeamSummary?,
                store: ActorStore,
                connectedAgentsStore: ConnectedAgentsStore? = nil,
                onReconnect: (() -> Void)? = nil) {
        self.pairing = pairing
        self.mqtt = mqtt
        self.sessionViewModel = sessionViewModel
        self.teamclawService = teamclawService
        self.activeTeam = activeTeam
        self.store = store
        self.connectedAgentsStore = connectedAgentsStore
        self.onReconnect = onReconnect
    }

    public var body: some View {
        NavigationStack {
            MemberListContent(
                store: store,
                pairing: pairing,
                mqtt: mqtt,
                sessionViewModel: sessionViewModel,
                teamclawService: teamclawService
            )
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
                                 connectedAgentsStore: connectedAgentsStore,
                                 activeTeam: activeTeam,
                                 onReconnect: onReconnect)
                }
                .sheet(isPresented: $showInvite) {
                    MemberInviteSheet(store: store)
                }
        }
    }
}
