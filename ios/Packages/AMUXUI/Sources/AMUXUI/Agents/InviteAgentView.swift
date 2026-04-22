import SwiftUI
import AMUXCore
import AMUXSharedUI

public struct InviteAgentView: View {
    let teamID: UUID
    let service: InviteAgentService

    @State private var displayName: String = ""
    @State private var invite: InvitePayload?
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    public init(teamID: UUID, service: InviteAgentService) {
        self.teamID = teamID
        self.service = service
    }

    public var body: some View {
        NavigationStack {
            Form {
                if let invite {
                    Section("Scan or share") {
                        JoinURLQRView(url: invite.joinURL)
                        Text("Expires at \(invite.expiresAt.formatted(date: .omitted, time: .shortened))")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section("Agent name") {
                        TextField("e.g. Matt's MacBook", text: $displayName)
                            .disabled(isSubmitting)
                    }
                    if let errorMessage {
                        Section {
                            Text(errorMessage).foregroundStyle(.red)
                        }
                    }
                    Section {
                        Button(action: submit) {
                            if isSubmitting { ProgressView() } else { Text("Create invite") }
                        }
                        .disabled(displayName.isEmpty || isSubmitting)
                    }
                }
            }
            .navigationTitle("Invite Agent")
        }
    }

    private func submit() {
        isSubmitting = true
        errorMessage = nil
        let name = displayName
        Task {
            do {
                let payload = try await service.createInvite(
                    teamID: teamID,
                    displayName: name
                )
                await MainActor.run {
                    self.invite = payload
                    self.isSubmitting = false
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isSubmitting = false
                }
            }
        }
    }
}
