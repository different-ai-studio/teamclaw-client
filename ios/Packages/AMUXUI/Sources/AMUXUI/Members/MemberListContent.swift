import SwiftUI
import SwiftData
import AMUXCore

// MARK: - MemberListContent

/// Browse-mode member list body. No NavigationStack; parent provides it.
/// Used as the pushable content in MembersTab.
public struct MemberListContent: View {
    @State private var viewModel = MemberListViewModel()
    @Environment(\.modelContext) private var modelContext
    let mqtt: MQTTService
    let deviceId: String
    let peerId: String

    public init(mqtt: MQTTService, deviceId: String, peerId: String) {
        self.mqtt = mqtt
        self.deviceId = deviceId
        self.peerId = peerId
    }

    public var body: some View {
        List {
            ForEach(viewModel.members, id: \.memberId) { member in
                NavigationLink {
                    MemberDetailView(member: member)
                } label: {
                    MemberRow(member: member)
                }
            }
        }
        .task { viewModel.start(mqtt: mqtt, deviceId: deviceId, modelContext: modelContext) }
    }
}

// MARK: - MemberRow

private struct MemberRow: View {
    let member: Member

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(member.displayName).font(.body)
                Text(member.roleLabel).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if member.isOwner {
                Image(systemName: "crown.fill").foregroundStyle(.orange).font(.caption)
            }
        }
    }
}

// MARK: - MemberDetailView

private struct MemberDetailView: View {
    let member: Member

    var body: some View {
        List {
            Section("Info") {
                LabeledContent("Name", value: member.displayName)
                LabeledContent("Role", value: member.roleLabel)
                LabeledContent("Joined", value: member.joinedAt.formatted(date: .abbreviated, time: .shortened))
            }
            Section("ID") {
                Text(member.memberId)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .navigationTitle(member.displayName)
        .navigationBarTitleDisplayMode(.inline)
    }
}
