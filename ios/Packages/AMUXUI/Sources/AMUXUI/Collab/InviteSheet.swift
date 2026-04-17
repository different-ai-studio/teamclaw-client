import SwiftUI
import SwiftData
import AMUXCore

public struct InviteSheet: View {
    let session: CollabSession
    let teamclawService: TeamclawService
    let teamId: String
    let deviceId: String

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var members: [Member] = []
    @State private var selectedIds: Set<String> = []

    public init(session: CollabSession, teamclawService: TeamclawService, teamId: String, deviceId: String) {
        self.session = session
        self.teamclawService = teamclawService
        self.teamId = teamId
        self.deviceId = deviceId
    }

    public var body: some View {
        NavigationStack {
            List(members, id: \.memberId) { member in
                HStack {
                    Text(member.displayName)
                    Spacer()
                    if selectedIds.contains(member.memberId) {
                        Image(systemName: "checkmark")
                            .foregroundStyle(.blue)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    if selectedIds.contains(member.memberId) {
                        selectedIds.remove(member.memberId)
                    } else {
                        selectedIds.insert(member.memberId)
                    }
                }
            }
            .navigationTitle("Invite to Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.secondary)
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { sendInvites() } label: {
                        Text("Invite")
                            .font(.subheadline).fontWeight(.medium)
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 14).padding(.vertical, 6)
                            .liquidGlass(in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(selectedIds.isEmpty)
                    .opacity(selectedIds.isEmpty ? 0.4 : 1)
                }
            }
            .task { loadMembers() }
        }
    }

    private func loadMembers() {
        let descriptor = FetchDescriptor<Member>(sortBy: [SortDescriptor(\.displayName)])
        members = (try? modelContext.fetch(descriptor)) ?? []
    }

    private func sendInvites() {
        guard let mqtt = teamclawService.mqttRef else { return }

        for memberId in selectedIds {
            var invite = Teamclaw_Invite()
            invite.inviteID = String(UUID().uuidString.prefix(8).lowercased())
            invite.sessionID = session.sessionId
            invite.teamID = teamId
            invite.hostDeviceID = session.hostDeviceId
            invite.invitedActorID = memberId
            invite.sessionTitle = session.title
            invite.summary = session.summary
            invite.createdAt = Int64(Date().timeIntervalSince1970)

            var envelope = Teamclaw_InviteEnvelope()
            envelope.invite = invite

            let topic = "teamclaw/\(teamId)/user/\(memberId)/invites"
            if let data = try? envelope.serializedData() {
                Task {
                    try? await mqtt.publish(topic: topic, payload: data, retain: false)
                }
            }
        }

        dismiss()
    }
}
