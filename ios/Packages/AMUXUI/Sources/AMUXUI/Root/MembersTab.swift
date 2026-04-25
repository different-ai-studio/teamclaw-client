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
    /// One-shot trigger from the parent (e.g. the zero-agent reminder) to
    /// open the invite sheet without a toolbar tap. Toggled back to false
    /// after firing so subsequent triggers re-fire cleanly.
    @Binding var externalInviteTrigger: Bool
    var onReconnect: (() -> Void)?
    var onSignOut: (() -> Void)?

    @State private var showSettings = false
    @State private var showInvite   = false

    public init(pairing: PairingManager,
                mqtt: MQTTService,
                sessionViewModel: SessionListViewModel,
                teamclawService: TeamclawService?,
                activeTeam: TeamSummary?,
                store: ActorStore,
                connectedAgentsStore: ConnectedAgentsStore? = nil,
                showInvite: Binding<Bool> = .constant(false),
                onReconnect: (() -> Void)? = nil,
                onSignOut: (() -> Void)? = nil) {
        self.pairing = pairing
        self.mqtt = mqtt
        self.sessionViewModel = sessionViewModel
        self.teamclawService = teamclawService
        self.activeTeam = activeTeam
        self.store = store
        self.connectedAgentsStore = connectedAgentsStore
        self._externalInviteTrigger = showInvite
        self.onReconnect = onReconnect
        self.onSignOut = onSignOut
    }

    public var body: some View {
        NavigationStack {
            MemberListContent(
                store: store,
                pairing: pairing,
                mqtt: mqtt,
                sessionViewModel: sessionViewModel,
                teamclawService: teamclawService,
                connectedAgentsStore: connectedAgentsStore,
                onAddYourAgent: { showInvite = true }
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
                            Image(systemName: "person.badge.plus")
                                .font(.title3)
                                .accessibilityHidden(true)
                        }
                        .buttonStyle(.plain)
                        .disabled(activeTeam == nil)
                        .opacity(activeTeam == nil ? 0.4 : 1)
                        .accessibilityLabel("Invite Member")
                        .accessibilityIdentifier("members.inviteButton")
                    }
                }
                .sheet(isPresented: $showSettings) {
                    SettingsView(pairing: pairing,
                                 connectedAgentsStore: connectedAgentsStore,
                                 activeTeam: activeTeam,
                                 onReconnect: onReconnect,
                                 onSignOut: onSignOut)
                }
                .sheet(isPresented: $showInvite) {
                    MemberInviteSheet(store: store)
                }
                .onChange(of: externalInviteTrigger) { _, newValue in
                    guard newValue else { return }
                    showInvite = true
                    externalInviteTrigger = false
                }
        }
    }
}
