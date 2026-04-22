import SwiftUI
import SwiftData
import AMUXCore

#if os(iOS)

public struct MemberListContent: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \CachedActor.displayName) private var actors: [CachedActor]
    @State private var searchText = ""

    let store: ActorStore

    public init(store: ActorStore) { self.store = store }

    private var filtered: [CachedActor] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return actors }
        let norm = q.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        return actors.filter { a in
            [a.displayName, a.roleLabel, a.agentKind ?? "", a.actorId]
                .joined(separator: " ")
                .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
                .contains(norm)
        }
    }

    public var body: some View {
        Group {
            if actors.isEmpty {
                ContentUnavailableView("No Actors Yet", systemImage: "person.2",
                                       description: Text("Invite teammates or agents to see them here."))
            } else if filtered.isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else {
                List {
                    ForEach(filtered, id: \.actorId) { a in
                        NavigationLink {
                            ActorDetailView(actor: a)
                        } label: {
                            ActorRow(actor: a)
                        }
                    }
                }
            }
        }
        .searchable(text: $searchText, prompt: "Search actors")
        .task { await store.reload(); await store.heartbeat() }
        .refreshable { await store.reload() }
    }
}

private struct ActorRow: View {
    let actor: CachedActor
    var body: some View {
        HStack {
            Circle().fill(actor.isOnline ? Color.green : Color.secondary.opacity(0.4))
                    .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(actor.displayName).font(.body)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(actor.isOnline ? "Online" : "Offline")
                .font(.caption)
                .foregroundStyle(actor.isOnline ? .green : .secondary)
            if actor.isOwner {
                Image(systemName: "crown.fill").foregroundStyle(.orange).font(.caption)
            }
        }
    }
    private var subtitle: String {
        if actor.isMember { return actor.roleLabel }
        let kind = actor.agentKind?.capitalized ?? "Agent"
        let status = actor.agentStatus ?? ""
        return status.isEmpty ? kind : "\(kind) · \(status)"
    }
}

private struct ActorDetailView: View {
    let actor: CachedActor
    var body: some View {
        List {
            Section("Info") {
                LabeledContent("Name", value: actor.displayName)
                LabeledContent("Kind", value: actor.isMember ? "Human" : "Agent")
                if actor.isMember {
                    LabeledContent("Role",   value: actor.roleLabel)
                    LabeledContent("Status", value: actor.memberStatus?.capitalized ?? "—")
                } else {
                    LabeledContent("Agent kind", value: actor.agentKind ?? "—")
                    LabeledContent("Status",     value: actor.agentStatus?.capitalized ?? "—")
                }
                LabeledContent("Joined",
                               value: actor.createdAt.formatted(date: .abbreviated, time: .shortened))
            }
            Section("ID") {
                Text(actor.actorId).font(.caption)
                    .foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .navigationTitle(actor.displayName)
        .navigationBarTitleDisplayMode(.inline)
    }
}

#else
struct MemberListContent: View {
    init(store: ActorStore) {}
    var body: some View { ContentUnavailableView("Actors", systemImage: "person.2") }
}
#endif
