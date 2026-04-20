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
    /// Peer identifier sent in every PeerAnnounce. Derived from the first six
    /// characters of the auth token so the daemon's token-prefix fallback
    /// (`AuthManager.find_role_by_token_prefix`) can recover this peer's role
    /// after a daemon restart — same convention iOS uses. Empty until the
    /// first `connectIfNeeded` run, so don't read this before pairing is set.
    public private(set) var peerId: String = ""
    private var connecting = false

    public init() {}

    /// Establishes the MQTT session if not already connected. Safe to call
    /// repeatedly; concurrent callers are coalesced via the `connecting` flag.
    public func connectIfNeeded(pairing: PairingManager) async {
        guard mqtt == nil, !connecting, pairing.isPaired else { return }
        connecting = true
        defer { connecting = false }

        if peerId.isEmpty {
            peerId = "mac-\(pairing.authToken.prefix(6))"
        }

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
