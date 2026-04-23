import SwiftUI
import SwiftData
import AMUXCore

// MARK: - MemberListView (a.k.a. ActorPicker)

/// Sheet-style picker over `CachedActor` rows with search, kind badges,
/// and permission gating for agents. Pure multi-select: humans and agents
/// can all be picked together. The caller decides what to do with the
/// result — for sessions without a primary agent, the caller is expected
/// to follow up with a `PrimaryAgentSheet` to resolve which selected agent
/// becomes primary.
public struct MemberListView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \CachedActor.displayName)
    private var actors: [CachedActor]

    private let selectionMode: Bool
    private let accessibleAgentIDs: Set<String>
    private let currentPrimaryAgentID: String?
    private let excludeActorID: String?
    @State private var selectedIDs: Set<String>
    @State private var searchText: String = ""
    private let onConfirm: (([CachedActor]) -> Void)?

    /// Browse-only mode: tap rows to see detail.
    public init() {
        self.selectionMode = false
        self.accessibleAgentIDs = []
        self.currentPrimaryAgentID = nil
        self.excludeActorID = nil
        self._selectedIDs = State(initialValue: [])
        self.onConfirm = nil
    }

    /// Selection mode: multi-select with a confirm callback.
    public init(selected: Set<String> = [],
                accessibleAgentIDs: Set<String> = [],
                currentPrimaryAgentID: String? = nil,
                excludeActorID: String? = nil,
                onConfirm: @escaping (_ actors: [CachedActor]) -> Void) {
        self.selectionMode = true
        self.accessibleAgentIDs = accessibleAgentIDs
        self.currentPrimaryAgentID = currentPrimaryAgentID
        self.excludeActorID = excludeActorID
        self._selectedIDs = State(initialValue: selected)
        self.onConfirm = onConfirm
    }

    private var visibleActors: [CachedActor] {
        // When the caller declares which agents we have access to, agents
        // outside that set are hidden from the picker (instead of shown
        // locked). Humans are always visible; browse mode (empty set) shows
        // everything too. `excludeActorID` hides the calling user from their
        // own collaborator list.
        var rows = actors
        if let exclude = excludeActorID, !exclude.isEmpty {
            rows = rows.filter { $0.actorId != exclude }
        }
        guard selectionMode, !accessibleAgentIDs.isEmpty else { return rows }
        return rows.filter { !$0.isAgent || accessibleAgentIDs.contains($0.actorId) }
    }

    private var filtered: [CachedActor] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return visibleActors }
        let norm = q.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        return visibleActors.filter { a in
            [a.displayName, a.roleLabel, a.agentKind ?? "", a.actorId]
                .joined(separator: " ")
                .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
                .contains(norm)
        }
    }

    public var body: some View {
        NavigationStack {
            List {
                ForEach(filtered, id: \.actorId) { actor in
                    if selectionMode {
                        selectionRow(actor)
                    } else {
                        NavigationLink {
                            MemberDetailView(member: actor)
                        } label: {
                            ActorRow(actor: actor, isPrimary: false, isLocked: false)
                        }
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Search actors")
            .navigationTitle("Actors").navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    if selectionMode {
                        Button {
                            let selected = actors.filter { selectedIDs.contains($0.actorId) }
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

    private func isLocked(_ actor: CachedActor) -> Bool {
        actor.isAgent && !accessibleAgentIDs.contains(actor.actorId)
    }

    private func isPrimary(_ actor: CachedActor) -> Bool {
        actor.isAgent && currentPrimaryAgentID == actor.actorId
    }

    @ViewBuilder
    private func selectionRow(_ actor: CachedActor) -> some View {
        let locked = isLocked(actor)
        Button {
            guard !locked else { return }
            if selectedIDs.contains(actor.actorId) {
                selectedIDs.remove(actor.actorId)
            } else {
                selectedIDs.insert(actor.actorId)
            }
        } label: {
            HStack {
                Image(systemName: selectedIDs.contains(actor.actorId) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selectedIDs.contains(actor.actorId) ? Color.accentColor
                                     : locked ? Color.secondary.opacity(0.4) : Color.secondary)
                    .font(.title3)
                ActorRow(actor: actor, isPrimary: isPrimary(actor), isLocked: locked)
            }
            .contentShape(Rectangle())
        }
        .tint(.primary)
        .disabled(locked)
    }
}

// MARK: - PrimaryAgentSheet

/// Second-step confirmation sheet used when a session has no primary agent
/// yet and the user has just picked one or more agents in the actor picker.
/// Asks them which of those agents should become the session's primary.
public struct PrimaryAgentSheet: View {
    @Environment(\.dismiss) private var dismiss
    private let candidates: [CachedActor]
    @State private var selectedID: String?
    private let onConfirm: (_ primaryAgentID: String) -> Void

    public init(candidates: [CachedActor],
                onConfirm: @escaping (String) -> Void) {
        self.candidates = candidates
        self._selectedID = State(initialValue: candidates.first?.actorId)
        self.onConfirm = onConfirm
    }

    public var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(candidates, id: \.actorId) { agent in
                        Button {
                            selectedID = agent.actorId
                        } label: {
                            HStack {
                                Image(systemName: selectedID == agent.actorId ? "largecircle.fill.circle" : "circle")
                                    .foregroundStyle(selectedID == agent.actorId ? Color.accentColor : .secondary)
                                    .font(.title3)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(agent.displayName).font(.body)
                                    if let kind = agent.agentKind, !kind.isEmpty {
                                        Text(kind.capitalized)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("Pick the agent that will drive this session")
                } footer: {
                    Text("The primary agent owns the session's model and receives prompts. Other agents and humans participate as collaborators.")
                }
            }
            .navigationTitle("Primary Agent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        if let id = selectedID { onConfirm(id) }
                        dismiss()
                    } label: {
                        Image(systemName: "checkmark").font(.title3)
                    }
                    .buttonStyle(.plain)
                    .disabled(selectedID == nil)
                }
                ToolbarItem(placement: .navigationBarLeading) {
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
}

// MARK: - ActorRow

private struct ActorRow: View {
    let actor: CachedActor
    let isPrimary: Bool
    let isLocked: Bool

    private var subtitle: String {
        if actor.isMember { return actor.roleLabel }
        let kind = actor.agentKind?.capitalized ?? "Agent"
        let status = actor.agentStatus ?? ""
        return status.isEmpty ? kind : "\(kind) · \(status)"
    }

    private var kindBadge: (String, Color) {
        actor.isMember ? ("Human", .blue) : ("Agent", .purple)
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(actor.isOnline ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(actor.displayName)
                        .font(.body)
                        .foregroundStyle(isLocked ? .secondary : .primary)
                    Text(kindBadge.0)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(kindBadge.1.opacity(0.15), in: Capsule())
                        .foregroundStyle(kindBadge.1)
                    if isPrimary {
                        Image(systemName: "star.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    if isLocked {
                        Image(systemName: "lock.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if actor.isOwner {
                Image(systemName: "crown.fill")
                    .foregroundStyle(.orange)
                    .font(.caption)
            }
        }
        .opacity(isLocked ? 0.55 : 1)
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
