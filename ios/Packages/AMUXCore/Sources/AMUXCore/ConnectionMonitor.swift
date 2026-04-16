import Foundation
import Observation

@Observable
public final class ConnectionMonitor {
    public private(set) var daemonOnline: Bool = false
    public private(set) var deviceName: String = ""
    private var task: Task<Void, Never>?

    public init() {}

    public func start(mqtt: MQTTService, deviceId: String) {
        task?.cancel()
        task = Task {
            let statusTopic = "amux/\(deviceId)/status"
            let stream = mqtt.messages()
            try? await mqtt.subscribe(statusTopic)

            for await msg in stream {
                guard msg.topic == statusTopic else { continue }
                if let status = try? ProtoMQTTCoder.decode(Amux_DeviceStatus.self, from: msg.payload) {
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
