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
        }
        .keyboardShortcut("m", modifiers: [.command, .shift])
    }
}

private struct MembersWindowView: View {
    let pairing: PairingManager
    @Environment(\.openWindow) private var openWindow
    @Environment(SharedConnection.self) private var shared

    var body: some View {
        MembersListView(
            mqtt: shared.mqtt,
            deviceId: pairing.deviceId
        )
        .navigationTitle("Team Members")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    openWindow(id: "amux.invite", value: InviteIntent.newMember(role: "member"))
                } label: {
                    Label("Invite", systemImage: "person.badge.plus")
                }
                .help("Invite a new member")
            }
        }
        .task { await shared.connectIfNeeded(pairing: pairing) }
    }
}
