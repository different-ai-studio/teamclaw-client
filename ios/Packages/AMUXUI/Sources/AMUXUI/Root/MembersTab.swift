import SwiftUI
import AMUXCore

public struct MembersTab: View {
    let mqtt: MQTTService
    let pairing: PairingManager
    let connectionMonitor: ConnectionMonitor
    let activeTeam: TeamSummary?
    let sessionViewModel: SessionListViewModel

    @State private var showSettings = false
    @State private var showInvite = false
    @State private var showInviteAgent = false

    public init(mqtt: MQTTService,
                pairing: PairingManager,
                connectionMonitor: ConnectionMonitor,
                activeTeam: TeamSummary?,
                sessionViewModel: SessionListViewModel) {
        self.mqtt = mqtt
        self.pairing = pairing
        self.connectionMonitor = connectionMonitor
        self.activeTeam = activeTeam
        self.sessionViewModel = sessionViewModel
    }

    public var body: some View {
        NavigationStack {
            MemberListContent(mqtt: mqtt,
                              deviceId: pairing.deviceId,
                              peerId: "ios-\(pairing.authToken.prefix(6))",
                              sessionViewModel: sessionViewModel)
                .navigationTitle("Actors")
                .navigationBarTitleDisplayMode(.large)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button { showSettings = true } label: {
                            Image(systemName: "gearshape").font(.title3).foregroundStyle(.primary)
                        }
                        .buttonStyle(.plain)
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button { showInvite = true } label: {
                            Image(systemName: "person.badge.plus").font(.title3)
                        }
                        .buttonStyle(.plain)
                        .disabled(activeTeam == nil)
                        .opacity(activeTeam == nil ? 0.4 : 1)
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button { showInviteAgent = true } label: {
                            Image(systemName: "person.crop.circle.badge.plus").font(.title3)
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
                    MemberInviteSheet(mqtt: mqtt,
                                      deviceId: pairing.deviceId,
                                      peerId: "ios-\(pairing.authToken.prefix(6))")
                }
                .sheet(isPresented: $showInviteAgent) {
                    if let rawTeamID = activeTeam?.id,
                       let teamID = UUID(uuidString: rawTeamID),
                       let configuration = try? SupabaseProjectConfiguration.fromMainBundle() {
                        InviteAgentView(teamID: teamID,
                                        service: InviteAgentService(configuration: configuration))
                    }
                }
        }
    }
}
