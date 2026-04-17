import SwiftUI
import SwiftData
import AMUXCore

public struct WorkspaceSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let mqtt: MQTTService
    let deviceId: String
    let peerId: String
    let viewModel: SessionListViewModel

    @State private var newPath = ""
    @State private var errorMessage: String?
    @State private var isAdding = false

    private var workspaces: [Workspace] { viewModel.workspaces }

    public init(mqtt: MQTTService, deviceId: String, peerId: String, viewModel: SessionListViewModel) {
        self.mqtt = mqtt
        self.deviceId = deviceId
        self.peerId = peerId
        self.viewModel = viewModel
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if workspaces.isEmpty {
                    ContentUnavailableView("No Workspaces", systemImage: "folder",
                        description: Text("Add a directory to get started"))
                } else {
                    List {
                        ForEach(workspaces, id: \.workspaceId) { ws in
                            Button {
                                newPath = ws.path
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(ws.displayName)
                                        .font(.body)
                                        .fontWeight(.medium)
                                    Text(ws.path)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    removeWorkspace(ws.workspaceId)
                                } label: {
                                    Label("Remove", systemImage: "trash")
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                }

                Spacer(minLength: 0)

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 4)
                }

                HStack(spacing: 8) {
                    TextField("Directory path (e.g. /Users/me/project)", text: $newPath)
                        .font(.subheadline)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .liquidGlass(in: Capsule())

                    if !newPath.trimmingCharacters(in: .whitespaces).isEmpty {
                        GlassCircleButton(icon: "plus") { addWorkspace() }
                            .disabled(isAdding)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .navigationTitle("Workspaces")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    GlassCircleButton(icon: "xmark", size: 32, iconFont: .caption) { dismiss() }
                }
            }
        }
    }

    private func addWorkspace() {
        let path = newPath.trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty else { return }

        isAdding = true
        errorMessage = nil

        Task {
            var envelope = Amux_DeviceCommandEnvelope()
            envelope.deviceID = deviceId
            envelope.peerID = peerId
            envelope.commandID = UUID().uuidString
            envelope.timestamp = Int64(Date().timeIntervalSince1970)
            var add = Amux_AddWorkspace()
            add.path = path
            var cmd = Amux_DeviceCollabCommand()
            cmd.command = .addWorkspace(add)
            envelope.command = cmd

            do {
                let data = try ProtoMQTTCoder.encode(envelope)
                try await mqtt.publish(topic: "amux/\(deviceId)/collab", payload: data)
            } catch {
                isAdding = false
                errorMessage = "Failed to send: \(error.localizedDescription)"
                return
            }

            let stream = mqtt.messages()
            let collabTopic = "amux/\(deviceId)/collab"
            let deadline = Date().addingTimeInterval(10)
            for await msg in stream {
                if Date() > deadline { break }
                if msg.topic == collabTopic,
                   let dce = try? ProtoMQTTCoder.decode(Amux_DeviceCollabEvent.self, from: msg.payload),
                   case .workspaceResult(let result) = dce.event,
                   result.commandID == envelope.commandID {
                    isAdding = false
                    if result.success {
                        newPath = ""
                        errorMessage = nil
                    } else {
                        errorMessage = result.error
                    }
                    return
                }
            }

            isAdding = false
            errorMessage = "Timed out waiting for response"
        }
    }

    private func removeWorkspace(_ workspaceId: String) {
        Task {
            var envelope = Amux_DeviceCommandEnvelope()
            envelope.deviceID = deviceId
            envelope.peerID = peerId
            envelope.commandID = UUID().uuidString
            envelope.timestamp = Int64(Date().timeIntervalSince1970)
            var remove = Amux_RemoveWorkspace()
            remove.workspaceID = workspaceId
            var cmd = Amux_DeviceCollabCommand()
            cmd.command = .removeWorkspace(remove)
            envelope.command = cmd

            if let data = try? ProtoMQTTCoder.encode(envelope) {
                try? await mqtt.publish(topic: "amux/\(deviceId)/collab", payload: data)
            }
        }
    }
}
