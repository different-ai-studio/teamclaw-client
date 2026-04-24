import Foundation
import Observation

/// Daemon-online signal driven by the retained `device/{id}/state` topic.
/// Offline = either an explicit offline payload OR the broker-cleared (empty)
/// retained message (Phase 3 daemon LWT fires here).
@Observable
public final class ConnectionMonitor {
    public private(set) var daemonOnline: Bool = false
    public private(set) var deviceName: String = ""
    private var task: Task<Void, Never>?

    public init() {}

    public func start(mqtt: MQTTService, teamID: String = "", deviceId: String) {
        task?.cancel()
        task = Task {
            let stateTopic = MQTTTopics.deviceState(teamID: teamID, deviceID: deviceId)
            let stream = mqtt.messages()
            try? await mqtt.subscribe(stateTopic)

            for await msg in stream {
                guard msg.topic == stateTopic else { continue }
                let online: Bool
                let name: String?
                if msg.payload.isEmpty {
                    online = false  // retained cleared → offline
                    name = nil
                } else if let s = try? ProtoMQTTCoder.decode(Amux_DeviceState.self, from: msg.payload) {
                    online = s.online
                    name = s.deviceName.isEmpty ? nil : s.deviceName
                } else {
                    continue  // unparseable; skip
                }

                await MainActor.run {
                    self.daemonOnline = online
                    if let name { self.deviceName = name }
                }
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }
}
