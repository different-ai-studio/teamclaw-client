import SwiftUI
import SwiftData
import AMUXCore

#if os(iOS)

// MARK: - MemberListContent

/// Browse-mode member list body. No NavigationStack; parent provides it.
/// Used as the pushable content in MembersTab.
public struct MemberListContent: View {
    @State private var viewModel = MemberListViewModel()
    @Environment(\.modelContext) private var modelContext
    let mqtt: MQTTService
    let deviceId: String
    let peerId: String
    let sessionViewModel: SessionListViewModel

    public init(mqtt: MQTTService,
                deviceId: String,
                peerId: String,
                sessionViewModel: SessionListViewModel) {
        self.mqtt = mqtt
        self.deviceId = deviceId
        self.peerId = peerId
        self.sessionViewModel = sessionViewModel
    }

    public var body: some View {
        List {
            ForEach(viewModel.members, id: \.memberId) { member in
                NavigationLink {
                    MemberDetailView(member: member,
                                     mqtt: mqtt,
                                     deviceId: deviceId,
                                     peerId: peerId,
                                     sessionViewModel: sessionViewModel,
                                     memberViewModel: viewModel)
                } label: {
                    MemberRow(member: member, isOnline: viewModel.isOnline(member))
                }
            }
        }
        .task { viewModel.start(mqtt: mqtt, deviceId: deviceId, modelContext: modelContext) }
    }
}
#else
struct MemberListContent: View {
    var body: some View {
        ContentUnavailableView("Members", systemImage: "person.2")
    }
}
#endif

// MARK: - MemberRow

private struct MemberRow: View {
    let member: Member
    let isOnline: Bool

    var body: some View {
        HStack {
            Circle()
                .fill(isOnline ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(member.displayName).font(.body)
                HStack(spacing: 6) {
                    Text(member.roleLabel)
                    Text("·").foregroundStyle(.tertiary)
                    Text(departmentLabel(for: member))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            // Placeholder: wire real count once session-participant mapping lands.
            Text("0 sessions")
                .font(.caption)
                .foregroundStyle(.tertiary)
            if member.isOwner {
                Image(systemName: "crown.fill").foregroundStyle(.orange).font(.caption)
            }
        }
    }
}

private func departmentLabel(for member: Member) -> String {
    if let dept = member.department, !dept.isEmpty { return dept }
    return "—"
}

// MARK: - MemberDetailView

private struct MemberDetailView: View {
    let member: Member
    let mqtt: MQTTService
    let deviceId: String
    let peerId: String
    let sessionViewModel: SessionListViewModel
    let memberViewModel: MemberListViewModel

    @Query private var allMessages: [SessionMessage]
    @Query(sort: \Session.lastMessageAt, order: .reverse)
    private var allSessions: [Session]

    @State private var showNewSession = false

    private var isOnline: Bool { memberViewModel.isOnline(member) }

    private var memberSessions: [Session] {
        let sessionIds = Set(
            allMessages
                .filter { $0.senderActorId == member.memberId }
                .map(\.sessionId)
        )
        return allSessions.filter { sessionIds.contains($0.sessionId) }
    }

    var body: some View {
        List {
            Section("Info") {
                LabeledContent("Name") {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(isOnline ? Color.green : Color.secondary.opacity(0.4))
                            .frame(width: 8, height: 8)
                        Text(member.displayName)
                    }
                }
                LabeledContent("Status", value: isOnline ? "Online" : "Offline")
                LabeledContent("Role", value: member.roleLabel)
                LabeledContent("Department", value: departmentLabel(for: member))
                LabeledContent("Joined", value: member.joinedAt.formatted(date: .abbreviated, time: .shortened))
            }
            Section("Collab Sessions") {
                if memberSessions.isEmpty {
                    Text("No sessions yet")
                        .font(.body)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(memberSessions, id: \.sessionId) { session in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(session.title.isEmpty ? "(untitled)" : session.title)
                                .font(.body)
                            if let last = session.lastMessageAt {
                                Text(last.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
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
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showNewSession = true
                } label: {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.title3)
                        .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("New session")
            }
        }
        .sheet(isPresented: $showNewSession) {
            NewSessionSheet(
                mqtt: mqtt,
                deviceId: deviceId,
                peerId: peerId,
                viewModel: sessionViewModel,
                preselectedCollaborators: [member]
            )
        }
    }
}
