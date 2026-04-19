import SwiftUI
import SwiftData
import AMUXCore

public struct WorkspaceSheet: View {
    @Environment(\.dismiss) private var dismiss

    let mqtt: MQTTService
    let deviceId: String
    let peerId: String
    let viewModel: SessionListViewModel

    public init(mqtt: MQTTService, deviceId: String, peerId: String, viewModel: SessionListViewModel) {
        self.mqtt = mqtt
        self.deviceId = deviceId
        self.peerId = peerId
        self.viewModel = viewModel
    }

    public var body: some View {
        NavigationStack {
            WorkspaceManagementView(mqtt: mqtt, deviceId: deviceId, peerId: peerId, viewModel: viewModel)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button { dismiss() } label: {
                            Image(systemName: "xmark")
                                .font(.title3).foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
        }
    }
}
