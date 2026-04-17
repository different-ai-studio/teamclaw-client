import SwiftUI
import AMUXCore

public struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    let pairing: PairingManager
    let connectionMonitor: ConnectionMonitor

    public init(pairing: PairingManager, connectionMonitor: ConnectionMonitor) {
        self.pairing = pairing; self.connectionMonitor = connectionMonitor
    }

    public var body: some View {
        NavigationStack {
            List {
                Section("Connection") {
                    HStack { Text("Daemon"); Spacer(); ConnectionStatusBadge(isOnline: connectionMonitor.daemonOnline, deviceName: connectionMonitor.deviceName) }
                    HStack { Text("Broker"); Spacer(); Text(pairing.brokerHost).foregroundStyle(.secondary) }
                    Button {
                        UIPasteboard.general.string = pairing.deviceId
                    } label: {
                        HStack {
                            Text("Device ID").foregroundStyle(.primary)
                            Spacer()
                            Text(String(pairing.deviceId.prefix(12)) + "...")
                                .foregroundStyle(.secondary)
                                .font(.caption.monospaced())
                            Image(systemName: "doc.on.doc")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Section {
                    Button {
                        pairing.unpair(); dismiss()
                    } label: {
                        Text("Unpair Device")
                            .font(.body).fontWeight(.medium)
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .liquidGlass(in: Capsule(), tint: .red)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
            }
            .navigationTitle("Settings").navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    GlassCircleButton(icon: "xmark", size: 32, iconFont: .caption) { dismiss() }
                }
            }
        }
    }
}
