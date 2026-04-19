import SwiftUI
import AMUXCore

/// Modal for inviting a new member. Extracted from MemberListView
/// so MembersTab can present it from its toolbar.
public struct MemberInviteSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel = MemberListViewModel()
    let mqtt: MQTTService
    let deviceId: String
    let peerId: String

    @State private var inviteName = ""
    @State private var inviteRole: Amux_MemberRole = .member

    public init(mqtt: MQTTService, deviceId: String, peerId: String) {
        self.mqtt = mqtt
        self.deviceId = deviceId
        self.peerId = peerId
    }

    public var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $inviteName)
                Picker("Role", selection: $inviteRole) {
                    Text("Member").tag(Amux_MemberRole.member)
                    Text("Owner").tag(Amux_MemberRole.owner)
                }
            }
            .navigationTitle("Invite Member")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        inviteName = ""; inviteRole = .member; dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        Task {
                            try? await viewModel.invite(displayName: inviteName,
                                                        role: inviteRole,
                                                        mqtt: mqtt,
                                                        deviceId: deviceId,
                                                        peerId: peerId)
                            inviteName = ""; inviteRole = .member
                        }
                        dismiss()
                    } label: {
                        Text("Invite")
                            .font(.subheadline).fontWeight(.medium)
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 14).padding(.vertical, 6)
                            .liquidGlass(in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(inviteName.trimmingCharacters(in: .whitespaces).isEmpty)
                    .opacity(inviteName.trimmingCharacters(in: .whitespaces).isEmpty ? 0.4 : 1)
                }
            }
        }
        .presentationDetents([.medium])
    }
}
