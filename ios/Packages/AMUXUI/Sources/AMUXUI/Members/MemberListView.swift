import SwiftUI
import SwiftData
import AMUXCore

// MARK: - MemberListView

public struct MemberListView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel = MemberListViewModel()
    @State private var showInvite = false
    @State private var inviteName = ""
    @State private var inviteRole: Amux_MemberRole = .member
    let mqtt: MQTTService
    let deviceId: String
    let peerId: String

    private let selectionMode: Bool
    @State private var selectedIDs: Set<String>
    private let onConfirm: (([Member]) -> Void)?

    /// Display mode — browse members, tap for detail
    public init(mqtt: MQTTService, deviceId: String, peerId: String) {
        self.mqtt = mqtt; self.deviceId = deviceId; self.peerId = peerId
        self.selectionMode = false
        self._selectedIDs = State(initialValue: [])
        self.onConfirm = nil
    }

    /// Selection mode — multi-select with confirm callback
    public init(mqtt: MQTTService, deviceId: String, peerId: String,
                selected: Set<String> = [],
                onConfirm: @escaping ([Member]) -> Void) {
        self.mqtt = mqtt; self.deviceId = deviceId; self.peerId = peerId
        self.selectionMode = true
        self._selectedIDs = State(initialValue: selected)
        self.onConfirm = onConfirm
    }

    public var body: some View {
        NavigationStack {
            List {
                ForEach(viewModel.members, id: \.memberId) { member in
                    if selectionMode {
                        selectionRow(member)
                    } else {
                        NavigationLink {
                            MemberDetailView(member: member)
                        } label: {
                            MemberRow(member: member)
                        }
                    }
                }
            }
            .navigationTitle("Members").navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    if selectionMode {
                        Button {
                            let selected = viewModel.members.filter { selectedIDs.contains($0.memberId) }
                            onConfirm?(selected)
                            dismiss()
                        } label: {
                            Image(systemName: "checkmark")
                        }
                        .disabled(selectedIDs.isEmpty)
                    } else {
                        Button { showInvite = true } label: { Image(systemName: "person.badge.plus") }
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                }
            }
            .sheet(isPresented: $showInvite) {
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
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { inviteName = ""; inviteRole = .member; showInvite = false }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Invite") {
                                Task {
                                    try? await viewModel.invite(displayName: inviteName, role: inviteRole, mqtt: mqtt, deviceId: deviceId, peerId: peerId)
                                    inviteName = ""; inviteRole = .member
                                }
                                showInvite = false
                            }
                            .disabled(inviteName.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                }
                .presentationDetents([.medium])
            }
        }
        .task { viewModel.start(mqtt: mqtt, deviceId: deviceId, modelContext: modelContext) }
    }

    @ViewBuilder
    private func selectionRow(_ member: Member) -> some View {
        Button {
            if selectedIDs.contains(member.memberId) {
                selectedIDs.remove(member.memberId)
            } else {
                selectedIDs.insert(member.memberId)
            }
        } label: {
            HStack {
                Image(systemName: selectedIDs.contains(member.memberId) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selectedIDs.contains(member.memberId) ? Color.accentColor : Color.secondary)
                    .font(.title3)
                MemberRow(member: member)
            }
        }
        .tint(.primary)
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
