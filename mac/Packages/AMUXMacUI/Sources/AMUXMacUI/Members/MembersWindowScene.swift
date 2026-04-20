import SwiftUI
import SwiftData
import AMUXCore

public struct MembersWindowScene: Scene {
    let pairing: PairingManager

    public init(pairing: PairingManager) {
        self.pairing = pairing
    }

    public var body: some Scene {
        Window("Members", id: "amux.members") {
            MembersWindowView(pairing: pairing)
                .frame(minWidth: 480, minHeight: 540)
                .modelContainer(for: [
                    Agent.self,
                    AgentEvent.self,
                    Member.self,
                    CollabSession.self,
                    SessionMessage.self,
                    WorkItem.self,
                    Workspace.self,
                ])
        }
        .keyboardShortcut("m", modifiers: [.command, .shift])
    }
}

private struct MembersWindowView: View {
    let pairing: PairingManager
    @Environment(\.openWindow) private var openWindow
    @Environment(SharedConnection.self) private var shared

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Team Members").font(.title3.weight(.semibold))
                Spacer()
                Button {
                    openWindow(id: "amux.invite", value: InviteIntent.newMember(role: "member"))
                } label: {
                    Label("Invite", systemImage: "person.badge.plus")
                }
            }
            .padding(16)
            Divider()
            MembersListView(
                mqtt: shared.mqtt,
                deviceId: pairing.deviceId,
                peerId: shared.peerId,
                onInviteTapped: {
                    openWindow(id: "amux.invite", value: InviteIntent.newMember(role: "member"))
                }
            )
        }
        .task { await shared.connectIfNeeded(pairing: pairing) }
    }
}
