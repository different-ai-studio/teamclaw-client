import SwiftUI
import AMUXCore

public struct NewCollabSheet: View {
    let teamclawService: TeamclawService
    let teamId: String
    let deviceId: String
    let peerId: String
    let onCreated: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var summary = ""
    @State private var isSending = false

    public init(
        teamclawService: TeamclawService,
        teamId: String,
        deviceId: String,
        peerId: String,
        onCreated: @escaping (String) -> Void
    ) {
        self.teamclawService = teamclawService
        self.teamId = teamId
        self.deviceId = deviceId
        self.peerId = peerId
        self.onCreated = onCreated
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section("Session") {
                    TextField("Title", text: $title)
                    TextField("Summary (optional)", text: $summary, axis: .vertical)
                        .lineLimit(3...6)
                }
            }
            .navigationTitle("New Collab Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { createSession() }
                        .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending)
                }
            }
        }
    }

    private func createSession() {
        guard let mqtt = teamclawService.mqttRef else { return }
        isSending = true

        var createReq = Teamclaw_CreateSessionRequest()
        createReq.sessionType = .collab
        createReq.teamID = teamId
        createReq.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        createReq.summary = summary.trimmingCharacters(in: .whitespacesAndNewlines)

        var rpcReq = Teamclaw_RpcRequest()
        rpcReq.requestID = String(UUID().uuidString.prefix(8).lowercased())
        rpcReq.senderDeviceID = deviceId
        rpcReq.method = .createSession(createReq)

        let topic = "teamclaw/\(teamId)/rpc/\(deviceId)/\(rpcReq.requestID)/req"
        if let data = try? rpcReq.serializedData() {
            Task {
                try? await mqtt.publish(topic: topic, payload: data, retain: false)
            }
        }

        dismiss()
    }
}
