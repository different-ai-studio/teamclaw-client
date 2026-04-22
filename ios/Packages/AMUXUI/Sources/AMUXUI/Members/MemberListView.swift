import SwiftUI
import SwiftData
import AMUXCore

// MARK: - MemberListView

public struct MemberListView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(filter: #Predicate<CachedActor> { $0.actorType == "member" },
           sort: \CachedActor.displayName)
    private var members: [CachedActor]

    let mqtt: MQTTService
    let deviceId: String
    let peerId: String

    private let selectionMode: Bool
    @State private var selectedIDs: Set<String>
    private let onConfirm: (([CachedActor]) -> Void)?

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
                onConfirm: @escaping ([CachedActor]) -> Void) {
        self.mqtt = mqtt; self.deviceId = deviceId; self.peerId = peerId
        self.selectionMode = true
        self._selectedIDs = State(initialValue: selected)
        self.onConfirm = onConfirm
    }

    public var body: some View {
        NavigationStack {
            List {
                ForEach(members, id: \.actorId) { member in
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
                            let selected = members.filter { selectedIDs.contains($0.actorId) }
                            onConfirm?(selected)
                            dismiss()
                        } label: {
                            Image(systemName: "checkmark").font(.title3)
                        }
                        .buttonStyle(.plain)
                        .disabled(selectedIDs.isEmpty)
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private func selectionRow(_ member: CachedActor) -> some View {
        Button {
            if selectedIDs.contains(member.actorId) {
                selectedIDs.remove(member.actorId)
            } else {
                selectedIDs.insert(member.actorId)
            }
        } label: {
            HStack {
                Image(systemName: selectedIDs.contains(member.actorId) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selectedIDs.contains(member.actorId) ? Color.accentColor : Color.secondary)
                    .font(.title3)
                MemberRow(member: member)
            }
        }
        .tint(.primary)
    }
}

// MARK: - MemberRow

private struct MemberRow: View {
    let member: CachedActor

    var body: some View {
        HStack {
            Circle()
                .fill(member.isOnline ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(member.displayName).font(.body)
                Text(member.roleLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
    let member: CachedActor

    @Query private var allMessages: [SessionMessage]
    @Query(sort: \Session.lastMessageAt, order: .reverse)
    private var allSessions: [Session]

    private var memberSessions: [Session] {
        let sessionIds = Set(
            allMessages
                .filter { $0.senderActorId == member.actorId }
                .map(\.sessionId)
        )
        return allSessions.filter { sessionIds.contains($0.sessionId) }
    }

    var body: some View {
        List {
            Section("Info") {
                LabeledContent("Name", value: member.displayName)
                LabeledContent("Role", value: member.roleLabel)
                LabeledContent("Joined", value: member.createdAt.formatted(date: .abbreviated, time: .shortened))
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
                Text(member.actorId)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .navigationTitle(member.displayName)
        .navigationBarTitleDisplayMode(.inline)
    }
}
