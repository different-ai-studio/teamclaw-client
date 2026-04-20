import SwiftUI
import SwiftData
import AMUXCore

/// Mac-native member list. Not a port of iOS MemberListContent (which has
/// deep iOS-specific navigation chrome); this is a Mac-idiomatic plain list.
struct MembersListView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var viewModel = MemberListViewModel()
    let mqtt: MQTTService?
    let deviceId: String
    let peerId: String
    let onInviteTapped: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.members.isEmpty {
                ContentUnavailableView(
                    "No members yet",
                    systemImage: "person.2",
                    description: Text("Click Invite to generate a join link for a new member.")
                )
            } else {
                List(viewModel.members, id: \.memberId) { member in
                    MemberRowView(member: member, isOnline: viewModel.isOnline(member))
                }
                .listStyle(.inset)
            }
        }
        .task {
            if let mqtt {
                viewModel.start(mqtt: mqtt, deviceId: deviceId, modelContext: modelContext)
            }
        }
    }
}

private struct MemberRowView: View {
    let member: Member
    let isOnline: Bool

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(isOnline ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(member.displayName).font(.body)
                    if member.isOwner {
                        Image(systemName: "crown.fill")
                            .foregroundStyle(.orange)
                            .font(.caption2)
                    }
                }
                HStack(spacing: 6) {
                    Text(member.roleLabel)
                    if let dept = member.department, !dept.isEmpty {
                        Text("·").foregroundStyle(.tertiary)
                        Text(dept)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Text(isOnline ? "Online" : "Offline")
                .font(.caption)
                .foregroundStyle(isOnline ? .green : .secondary)
        }
        .padding(.vertical, 4)
    }
}
