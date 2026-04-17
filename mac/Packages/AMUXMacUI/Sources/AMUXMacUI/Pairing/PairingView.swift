import SwiftUI
import AMUXCore

public struct PairingView: View {
    let pairing: PairingManager
    @State private var input: String = ""
    @State private var error: String?
    @State private var isWorking = false
    @FocusState private var inputFocused: Bool

    public init(pairing: PairingManager) {
        self.pairing = pairing
    }

    public var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "link.circle.fill")
                .font(.system(size: 48, weight: .regular))
                .foregroundStyle(.tint)
                .padding(.top, 36)

            Text("Pair this Mac with your daemon")
                .font(.title2.weight(.semibold))

            Text("Run `amuxd invite mac` on the machine where the daemon runs, then paste the `amux://` URL below.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            TextField("amux://join?broker=…&device=…&token=…", text: $input, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...4)
                .focused($inputFocused)
                .padding(.horizontal, 32)
                .onSubmit { Task { await tryPair() } }

            if let error {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 32)
            }

            HStack(spacing: 12) {
                Button("Paste from Clipboard") { paste() }
                    .keyboardShortcut("v", modifiers: [.command])
                Spacer()
                Button("Pair") { Task { await tryPair() } }
                    .keyboardShortcut(.return)
                    .buttonStyle(.borderedProminent)
                    .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isWorking)
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 28)
        }
        .frame(width: 520)
        .onAppear { inputFocused = true }
    }

    private func paste() {
        if let s = NSPasteboard.general.string(forType: .string) {
            input = s
        }
    }

    private func tryPair() async {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed) else {
            error = "That doesn't look like a URL."
            return
        }
        isWorking = true
        defer { isWorking = false }
        do {
            try pairing.pair(from: url)
            error = nil
        } catch let pairError as PairingManager.PairingError {
            error = pairError.errorDescription
        } catch let caughtError {
            error = "Couldn't save credentials: \(caughtError.localizedDescription)"
        }
    }
}

#Preview {
    PairingView(pairing: PairingManager(store: UserDefaultsCredentialStore()))
}
