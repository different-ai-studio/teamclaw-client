import SwiftUI
import AMUXCore
import AMUXSharedUI

public struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    let pairing: PairingManager
    let connectionMonitor: ConnectionMonitor
    let mqtt: MQTTService
    let sessionViewModel: SessionListViewModel

    public init(pairing: PairingManager,
                connectionMonitor: ConnectionMonitor,
                mqtt: MQTTService,
                sessionViewModel: SessionListViewModel) {
        self.pairing = pairing
        self.connectionMonitor = connectionMonitor
        self.mqtt = mqtt
        self.sessionViewModel = sessionViewModel
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }

    private var currentWorkspaceName: String? {
        sessionViewModel.workspaces.first?.displayName
    }

    public var body: some View {
        NavigationStack {
            List {
                Section("Workspace") {
                    NavigationLink {
                        WorkspaceManagementView(mqtt: mqtt,
                                                deviceId: pairing.deviceId,
                                                peerId: "ios-\(pairing.authToken.prefix(6))",
                                                viewModel: sessionViewModel)
                    } label: {
                        HStack {
                            Image(systemName: "folder")
                            Text("Workspaces")
                            Spacer()
                            if let name = currentWorkspaceName {
                                Text(name)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }

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
                Section("About") {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text("\(appVersion) (\(buildNumber))")
                            .foregroundStyle(.secondary)
                            .font(.caption.monospaced())
                    }
                }
                Section {
                    Button {
                        try? pairing.unpair(); dismiss()
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
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
