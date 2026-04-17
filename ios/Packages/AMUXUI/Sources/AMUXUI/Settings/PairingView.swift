import SwiftUI
import AMUXCore

public struct PairingView: View {
    let pairing: PairingManager
    @State private var manualLink = ""
    @State private var errorMessage: String?

    public init(pairing: PairingManager) { self.pairing = pairing }

    public var body: some View {
        VStack(spacing: 32) {
            Spacer()
            Image(systemName: "antenna.radiowaves.left.and.right").font(.system(size: 64)).foregroundStyle(.blue)
            Text("Connect to AMUX Daemon").font(.title2).fontWeight(.bold)
            Text("Run `amuxd init` on your Mac, then scan the QR code or paste the deeplink below.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 32)
            VStack(spacing: 12) {
                TextField("amux://join?broker=...&device=...&token=...", text: $manualLink)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .font(.caption.monospaced())
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .liquidGlass(in: Capsule())
                    .padding(.horizontal, 24)
                Button {
                    guard let url = URL(string: manualLink.trimmingCharacters(in: .whitespacesAndNewlines)) else { errorMessage = "Invalid URL"; return }
                    do { try pairing.pair(from: url) } catch { errorMessage = error.localizedDescription }
                } label: {
                    Text("Connect")
                        .font(.body).fontWeight(.medium)
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 32).padding(.vertical, 10)
                        .liquidGlass(in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(manualLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .opacity(manualLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.4 : 1)
            }
            if let error = errorMessage { Text(error).font(.caption).foregroundStyle(.red) }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
