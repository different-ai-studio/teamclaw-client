import SwiftUI
import SwiftData
import AMUXCore

#if os(iOS)

public struct MemberInviteSheet: View {
    @Environment(\.dismiss) private var dismiss
    let store: ActorStore

    @State private var kind: InviteKind = .member
    @State private var name = ""
    @State private var teamRole: TeamRole = .member
    @State private var agentKind: String = "daemon"
    @State private var isInviting = false
    @State private var errorMessage: String?
    @State private var invite: InviteCreated?

    public init(store: ActorStore) { self.store = store }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var canInvite: Bool {
        !trimmedName.isEmpty && !isInviting && invite == nil
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Kind", selection: $kind) {
                        Text("Teammate").tag(InviteKind.member)
                        Text("Agent").tag(InviteKind.agent)
                    }
                    .pickerStyle(.segmented)
                    .disabled(invite != nil)

                    TextField("Name", text: $name).disabled(invite != nil)

                    if kind == .member {
                        Picker("Role", selection: $teamRole) {
                            Text("Member").tag(TeamRole.member)
                            Text("Admin").tag(TeamRole.admin)
                        }.disabled(invite != nil)
                    } else {
                        Picker("Agent kind", selection: $agentKind) {
                            Text("Daemon").tag("daemon")
                        }.disabled(invite != nil)
                    }
                } footer: {
                    if let errorMessage {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                }

                if let invite {
                    Section("Share invite") {
                        Text(invite.deeplink).font(.footnote)
                            .textSelection(.enabled).foregroundStyle(.secondary)
                        ShareLink(item: invite.deeplink) {
                            Label("Share link", systemImage: "square.and.arrow.up")
                        }
                        Button {
                            UIPasteboard.general.string = invite.deeplink
                        } label: {
                            Label("Copy link", systemImage: "doc.on.doc")
                        }
                        LabeledContent("Expires",
                                       value: invite.expiresAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                    }
                }
            }
            .navigationTitle("Invite")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { reset(); dismiss() } label: {
                        Image(systemName: "xmark").font(.title3).foregroundStyle(.secondary)
                    }.buttonStyle(.plain)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if invite != nil {
                        Button { reset(); dismiss() } label: { Text("Done") }
                    } else {
                        Button { run() } label: {
                            HStack(spacing: 6) {
                                if isInviting { ProgressView().controlSize(.small) }
                                Text("Invite")
                            }
                        }
                        .disabled(!canInvite)
                        .opacity(canInvite ? 1 : 0.4)
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func run() {
        errorMessage = nil
        guard canInvite else { return }
        isInviting = true
        Task {
            let input = InviteCreateInput(
                kind: kind, displayName: trimmedName,
                teamRole: kind == .member ? teamRole : nil,
                agentKind: kind == .agent ? agentKind : nil
            )
            if let created = await store.createInvite(input) {
                invite = created
            } else {
                errorMessage = store.errorMessage ?? "Failed to create invite."
            }
            isInviting = false
        }
    }

    private func reset() {
        kind = .member; name = ""; teamRole = .member; agentKind = "daemon"
        isInviting = false; errorMessage = nil; invite = nil
    }
}
#else
public struct MemberInviteSheet: View {
    public init(store: ActorStore) {}
    public var body: some View { Text("Invites are iOS-only.").padding(24) }
}
#endif
