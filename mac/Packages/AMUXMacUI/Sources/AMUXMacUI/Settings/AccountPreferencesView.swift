import SwiftUI
import AMUXCore

struct AccountPreferencesView: View {
    let pairing: PairingManager
    @State private var unpairConfirm = false
    @State private var unpairError: String?
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Form {
            Section("This Device") {
                LabeledContent("Device ID", value: pairing.deviceId)
                    .textSelection(.enabled)
            }

            Section("Daemon Pairing") {
                if pairing.isPaired {
                    LabeledContent("Broker", value: "\(pairing.brokerHost):\(pairing.brokerPort)")
                        .textSelection(.enabled)
                    LabeledContent("Transport", value: pairing.useTLS ? "TLS" : "Plain MQTT")
                    LabeledContent("Username", value: pairing.username.isEmpty ? "(none)" : pairing.username)
                        .textSelection(.enabled)
                } else {
                    Text("Not paired.")
                        .foregroundStyle(.secondary)
                }
            }

            if pairing.isPaired {
                Section("Invites") {
                    Button("Show Invite QR for a New Member\u{2026}") {
                        openWindow(id: "amux.invite", value: InviteIntent.newMember(role: "member"))
                    }
                }
                Section {
                    Button("Unpair this Device", role: .destructive) {
                        unpairConfirm = true
                    }
                    if let unpairError {
                        Text(unpairError)
                            .font(.callout)
                            .foregroundStyle(.red)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(width: 460, height: 400)
        .confirmationDialog(
            "Unpair this Mac?",
            isPresented: $unpairConfirm
        ) {
            Button("Unpair", role: .destructive) { performUnpair() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes the saved daemon credentials from Keychain. You'll need a new amux:// URL to pair again.")
        }
    }

    private func performUnpair() {
        do {
            try pairing.unpair()
            unpairError = nil
        } catch {
            unpairError = "Failed to unpair: \(error.localizedDescription)"
        }
    }
}
