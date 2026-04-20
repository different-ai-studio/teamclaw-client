import SwiftUI
import SwiftData
import AMUXCore

#if os(iOS)

/// Modal for inviting a new member. Extracted from MemberListView
/// so MembersTab can present it from its toolbar.
public struct MemberInviteSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var viewModel = MemberListViewModel()

    let mqtt: MQTTService
    let deviceId: String
    let peerId: String

    @State private var inviteName = ""
    @State private var inviteRole: Amux_MemberRole = .member
    @State private var isInviting = false
    @State private var errorMessage: String?
    @State private var inviteLink: String?
    @State private var expiresAt: Date?

    @Query private var allMembers: [Member]

    public init(mqtt: MQTTService, deviceId: String, peerId: String) {
        self.mqtt = mqtt
        self.deviceId = deviceId
        self.peerId = peerId
    }

    private var trimmedName: String {
        inviteName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isDuplicateName: Bool {
        guard !trimmedName.isEmpty else { return false }
        return allMembers.contains {
            $0.displayName.caseInsensitiveCompare(trimmedName) == .orderedSame
        }
    }

    private var canInvite: Bool {
        !trimmedName.isEmpty && !isDuplicateName && !isInviting && inviteLink == nil
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $inviteName)
                        .disabled(inviteLink != nil)
                    Picker("Role", selection: $inviteRole) {
                        Text("Member").tag(Amux_MemberRole.member)
                        Text("Owner").tag(Amux_MemberRole.owner)
                    }
                    .disabled(inviteLink != nil)
                } footer: {
                    if isDuplicateName {
                        Text("A member named \u{201C}\(trimmedName)\u{201D} already exists.")
                            .foregroundStyle(.red)
                    } else if let errorMessage {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                }

                if let inviteLink {
                    Section("Share invite") {
                        Text(inviteLink)
                            .font(.footnote)
                            .textSelection(.enabled)
                            .foregroundStyle(.secondary)
                        ShareLink(item: inviteLink) {
                            Label("Share link", systemImage: "square.and.arrow.up")
                        }
                        Button {
                            UIPasteboard.general.string = inviteLink
                        } label: {
                            Label("Copy link", systemImage: "doc.on.doc")
                        }
                        if let expiresAt {
                            LabeledContent("Expires",
                                           value: expiresAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                        }
                    }
                }
            }
            .navigationTitle("Invite Member")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { reset(); dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if inviteLink != nil {
                        Button { reset(); dismiss() } label: {
                            Text("Done")
                                .font(.subheadline).fontWeight(.medium)
                                .foregroundStyle(.primary)
                                .padding(.horizontal, 14).padding(.vertical, 6)
                                .liquidGlass(in: Capsule())
                        }
                        .buttonStyle(.plain)
                    } else {
                        Button {
                            runInvite()
                        } label: {
                            HStack(spacing: 6) {
                                if isInviting { ProgressView().controlSize(.small) }
                                Text("Invite")
                            }
                            .font(.subheadline).fontWeight(.medium)
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 14).padding(.vertical, 6)
                            .liquidGlass(in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(!canInvite)
                        .opacity(canInvite ? 1 : 0.4)
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .task {
            // Make the duplicate-name check work over the viewModel's live
            // member list too (used by inviteAndWait). @Query already feeds
            // the UI; this sync keeps the viewModel in step.
            viewModel.start(mqtt: mqtt, deviceId: deviceId, modelContext: modelContext)
        }
    }

    private func runInvite() {
        errorMessage = nil
        guard canInvite else { return }
        isInviting = true
        Task {
            do {
                let created = try await viewModel.inviteAndWait(
                    displayName: trimmedName,
                    role: inviteRole,
                    mqtt: mqtt,
                    deviceId: deviceId,
                    peerId: peerId
                )
                inviteLink = created.deeplink
                if created.expiresAt > 0 {
                    expiresAt = Date(timeIntervalSince1970: TimeInterval(created.expiresAt))
                }
            } catch MemberListViewModel.InviteError.duplicateName {
                errorMessage = "A member named \u{201C}\(trimmedName)\u{201D} already exists."
            } catch MemberListViewModel.InviteError.rejected(let reason) {
                errorMessage = reason
            } catch MemberListViewModel.InviteError.timedOut {
                errorMessage = "Timed out waiting for the daemon. Check amuxd logs."
            } catch {
                errorMessage = error.localizedDescription
            }
            isInviting = false
        }
    }

    private func reset() {
        inviteName = ""
        inviteRole = .member
        isInviting = false
        errorMessage = nil
        inviteLink = nil
        expiresAt = nil
    }
}
#else
public struct MemberInviteSheet: View {
    public init(mqtt: MQTTService, deviceId: String, peerId: String) {}

    public var body: some View {
        Text("Member invites are only available on iOS in AMUXUI.")
            .padding(24)
    }
}
#endif
