import Foundation
import Observation

/// Legacy daemon-online signal driven by the retained device status topic
/// retained topic (LWT). iOS no longer uses this — the app infers agent
/// liveness from Supabase `actors.last_active_at` via
/// `ConnectedAgentsStore`. Kept alive for the macOS shell, which still
/// surfaces a daemon-online dot in its sidebar.
///
/// Dual-subscribes to `device/{id}/status` (LWT crash-offline signal) and
/// `device/{id}/state` (normal-transition updates; takes over LWT in Phase 3).
/// Merge rule: offline-wins — if either topic reads offline, device is offline.
@Observable
public final class ConnectionMonitor {
    public private(set) var daemonOnline: Bool = false
    public private(set) var deviceName: String = ""
    private var task: Task<Void, Never>?

    // Two independent online readings — one per subscribed topic.
    // nil means no payload received yet from that topic.
    private var statusOnline: Bool? = nil
    private var stateOnline: Bool? = nil

    public init() {}

    public func start(mqtt: MQTTService, teamID: String = "", deviceId: String) {
        task?.cancel()
        statusOnline = nil
        stateOnline = nil
        task = Task {
            let statusTopic = MQTTTopics.deviceStatus(teamID: teamID, deviceID: deviceId)
            let stateTopic  = MQTTTopics.deviceState(teamID: teamID, deviceID: deviceId)
            let stream = mqtt.messages()
            try? await mqtt.subscribe(statusTopic)
            try? await mqtt.subscribe(stateTopic)

            for await msg in stream {
                if msg.topic == statusTopic {
                    if msg.payload.isEmpty {
                        // Empty retained = broker cleared the topic; treat as offline.
                        statusOnline = false
                    } else if let s = try? ProtoMQTTCoder.decode(Amux_DeviceState.self, from: msg.payload) {
                        statusOnline = s.online
                        // device name is authoritative on status (set by daemon at connect)
                        await MainActor.run { self.deviceName = s.deviceName }
                    }
                } else if msg.topic == stateTopic {
                    if msg.payload.isEmpty {
                        stateOnline = false
                    } else if let s = try? ProtoMQTTCoder.decode(Amux_DeviceState.self, from: msg.payload) {
                        stateOnline = s.online
                        // Mirror device name from state too in case status hasn't arrived yet.
                        if !s.deviceName.isEmpty {
                            await MainActor.run { self.deviceName = s.deviceName }
                        }
                    }
                } else {
                    continue
                }

                let merged = mergeOfflineWins(statusOnline, stateOnline)
                await MainActor.run { self.daemonOnline = merged }
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }

    /// Offline-wins merge per Phase 1a spec decision.
    /// If either source reports offline, the device is offline.
    /// If neither has data yet, conservatively return false.
    private func mergeOfflineWins(_ s: Bool?, _ t: Bool?) -> Bool {
        switch (s, t) {
        case (false, _), (_, false): return false  // either offline → offline
        case (true, _), (_, true):   return true   // neither offline, some data → online
        default:                     return false  // no data yet → conservative
        }
    }
}
