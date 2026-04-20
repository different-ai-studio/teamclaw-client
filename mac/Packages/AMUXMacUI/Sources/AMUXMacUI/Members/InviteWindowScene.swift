import SwiftUI
import AppKit
import AMUXCore
import AMUXSharedUI

public struct InviteWindowScene: Scene {
    let pairing: PairingManager

    public init(pairing: PairingManager) {
        self.pairing = pairing
    }

    public var body: some Scene {
        WindowGroup(id: "amux.invite", for: InviteIntent.self) { $intent in
            if let intent {
                InviteWindowView(intent: intent, pairing: pairing)
                    .frame(minWidth: 440, minHeight: 560)
            }
        }
        .windowResizability(.contentSize)
    }
}

private struct InviteWindowView: View {
    let intent: InviteIntent
    let pairing: PairingManager
    @Environment(SharedConnection.self) private var shared

    @State private var displayName: String = ""
    @State private var inviteURL: String?
    @State private var expiresAt: Date?
    @State private var isGenerating = false
    @State private var errorMessage: String?
    @State private var viewModel = MemberListViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Invite a new member").font(.title3.weight(.semibold))

            TextField("Display name (e.g. Alex)", text: $displayName)
                .textFieldStyle(.roundedBorder)

            if let inviteURL {
                VStack(alignment: .center, spacing: 12) {
                    QRCodeView(content: inviteURL)
                        .frame(width: 220, height: 220)
                    Text(inviteURL)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                    if let expiresAt {
                        Text("Expires \(expiresAt.formatted(date: .omitted, time: .shortened))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Button("Copy link") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(inviteURL, forType: .string)
                        }
                        Button("Share via Messages\u{2026}") {
                            let service = NSSharingService(named: .composeMessage)
                            service?.perform(withItems: [inviteURL])
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }

            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button(isGenerating ? "Generating\u{2026}" : (inviteURL == nil ? "Generate Invite" : "Regenerate")) {
                    generate()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(isGenerating || displayName.trimmingCharacters(in: .whitespaces).isEmpty || shared.mqtt == nil)
            }
        }
        .padding(24)
        .task { await shared.connectIfNeeded(pairing: pairing) }
    }

    private func generate() {
        let trimmed = displayName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let mqtt = shared.mqtt else { return }

        isGenerating = true
        errorMessage = nil

        let role: Amux_MemberRole
        switch intent {
        case .newMember(let roleStr):
            role = roleStr.lowercased() == "owner" ? .owner : .member
        }

        let deviceId = pairing.deviceId
        let peerId = shared.peerId

        Task {
            do {
                let created = try await viewModel.inviteAndWait(
                    displayName: trimmed,
                    role: role,
                    mqtt: mqtt,
                    deviceId: deviceId,
                    peerId: peerId
                )
                await MainActor.run {
                    inviteURL = created.deeplink
                    expiresAt = created.expiresAt > 0
                        ? Date(timeIntervalSince1970: TimeInterval(created.expiresAt))
                        : nil
                    isGenerating = false
                }
            } catch MemberListViewModel.InviteError.duplicateName {
                await MainActor.run {
                    isGenerating = false
                    errorMessage = "A member with that name already exists."
                }
            } catch MemberListViewModel.InviteError.timedOut {
                await MainActor.run {
                    isGenerating = false
                    errorMessage = "Timed out waiting for daemon response."
                }
            } catch MemberListViewModel.InviteError.rejected(let reason) {
                await MainActor.run {
                    isGenerating = false
                    errorMessage = reason
                }
            } catch {
                await MainActor.run {
                    isGenerating = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}
