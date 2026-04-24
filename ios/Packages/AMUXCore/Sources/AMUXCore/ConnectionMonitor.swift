import Foundation
import Observation

/// Legacy daemon-online signal driven by the retained device status topic
/// retained topic (LWT). iOS no longer uses this — the app infers agent
/// liveness from Supabase `actors.last_active_at` via
/// `ConnectedAgentsStore`. Kept alive for the macOS shell, which still
/// surfaces a daemon-online dot in its sidebar.
@Observable
public final class ConnectionMonitor {
    public private(set) var daemonOnline: Bool = false
    public private(set) var deviceName: String = ""
    private var task: Task<Void, Never>?

    public init() {}

    public func start(mqtt: MQTTService, teamID: String = "", deviceId: String) {
        task?.cancel()
        task = Task {
            let statusTopic = MQTTTopics.deviceStatus(teamID: teamID, deviceID: deviceId)
            let stream = mqtt.messages()
            try? await mqtt.subscribe(statusTopic)

            for await msg in stream {
                guard msg.topic == statusTopic else { continue }
                if let status = try? ProtoMQTTCoder.decode(Amux_DeviceState.self, from: msg.payload) {
                    await MainActor.run {
                        self.daemonOnline = status.online
                        self.deviceName = status.deviceName
                    }
                }
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }
}
