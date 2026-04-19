import SwiftUI
import AMUXCore

public struct PairingView: View {
    let pairing: PairingManager
    @State private var manualLink = ""
    @State private var errorMessage: String?
    @State private var showScanner = false

    public init(pairing: PairingManager) { self.pairing = pairing }

    public var body: some View {
        VStack(spacing: 28) {
            Spacer()

            Image("TeamclawLogo", bundle: .module)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 96, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .shadow(color: .black.opacity(0.08), radius: 8, x: 0, y: 4)

            Text("Connect to AMUX Daemon")
                .font(.title2).fontWeight(.bold)

            Text("Run `amuxd init` on your Mac, then scan the QR code or paste the deeplink below.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Button {
                errorMessage = nil
                showScanner = true
            } label: {
                Label("Scan QR code", systemImage: "qrcode.viewfinder")
                    .font(.body).fontWeight(.medium)
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 24).padding(.vertical, 12)
                    .liquidGlass(in: Capsule())
            }
            .buttonStyle(.plain)

            VStack(spacing: 12) {
                TextField("amux://join?broker=...&device=...&token=...", text: $manualLink)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.caption.monospaced())
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .liquidGlass(in: Capsule())
                    .padding(.horizontal, 24)
                Button {
                    connect(with: manualLink)
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

            if let error = errorMessage {
                Text(error).font(.caption).foregroundStyle(.red)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showScanner) {
            QRScannerView(
                onScanned: { value in
                    showScanner = false
                    manualLink = value
                    connect(with: value)
                },
                onCancel: { showScanner = false }
            )
        }
    }

    private func connect(with raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed) else {
            errorMessage = "Invalid URL"
            return
        }
        do {
            try pairing.pair(from: url)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
