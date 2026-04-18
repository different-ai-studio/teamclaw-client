import Foundation
import Observation
import AMUXCore

// MARK: - SharedConnection
//
// Process-wide holder for the MQTT connection and ConnectionMonitor so that
// every SwiftUI Scene (main window + detached session windows + settings)
// works against the same broker session. Lives on the App struct; injected
// into each Scene via `.environment(_:)`.
//
// Why centralize this? DetailWindowScene is its own WindowGroup, which means
// state declared inside MainWindowView is invisible to detached windows —
// leaving the agent-event feed dark in any second window. With a shared
// instance, AgentDetailViewModel can subscribe from either window.
//
// The connection is owned here; `connectIfNeeded(pairing:)` is idempotent and
// may be called from any Scene's `.task`. peerId is stable for the process so
// the daemon's peer registry stays consistent across windows.

@Observable @MainActor
public final class SharedConnection {
    public private(set) var mqtt: MQTTService?
    public private(set) var monitor: ConnectionMonitor?
    public let peerId: String
    private var connecting = false

    public init() {
        self.peerId = "mac-\(UUID().uuidString.prefix(6))"
    }

    /// Establishes the MQTT session if not already connected. Safe to call
    /// repeatedly; concurrent callers are coalesced via the `connecting` flag.
    public func connectIfNeeded(pairing: PairingManager) async {
        guard mqtt == nil, !connecting, pairing.isPaired else { return }
        connecting = true
        defer { connecting = false }

        let service = MQTTService()
        do {
            try await service.connect(
                host: pairing.brokerHost,
                port: pairing.brokerPort,
                username: pairing.username,
                password: pairing.password,
                clientId: "amux-mac-\(UUID().uuidString.prefix(6))",
                useTLS: pairing.useTLS
            )
        } catch {
            return
        }
        let mon = ConnectionMonitor()
        mon.start(mqtt: service, deviceId: pairing.deviceId)
        self.mqtt = service
        self.monitor = mon
    }
}
