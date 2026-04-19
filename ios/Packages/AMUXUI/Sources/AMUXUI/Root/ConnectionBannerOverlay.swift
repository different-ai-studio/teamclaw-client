import SwiftUI
import AMUXCore

/// Shows the current connection state as a pill banner at the top.
/// Used at the root of RootTabView so it appears over every tab.
public struct ConnectionBannerOverlay: View {
    let mqtt: MQTTService
    let connectionMonitor: ConnectionMonitor
    var onReconnect: (() -> Void)?

    public init(mqtt: MQTTService, connectionMonitor: ConnectionMonitor, onReconnect: (() -> Void)? = nil) {
        self.mqtt = mqtt
        self.connectionMonitor = connectionMonitor
        self.onReconnect = onReconnect
    }

    public var body: some View {
        VStack(spacing: 0) {
            if mqtt.connectionState == .reconnecting {
                ConnectionBanner(icon: "arrow.triangle.2.circlepath",
                                 text: "Reconnecting…", color: .yellow)
            } else if mqtt.connectionState == .disconnected {
                Button {
                    onReconnect?()
                } label: {
                    ConnectionBanner(icon: "bolt.slash.fill",
                                     text: "Not Connected · Tap to reconnect",
                                     color: .red)
                }
                .buttonStyle(.plain)
            } else if !connectionMonitor.daemonOnline {
                ConnectionBanner(icon: "desktopcomputer",
                                 text: "Daemon Offline", color: .orange)
            }
            Spacer(minLength: 0)
        }
        .allowsHitTesting(mqtt.connectionState == .disconnected)
    }
}
