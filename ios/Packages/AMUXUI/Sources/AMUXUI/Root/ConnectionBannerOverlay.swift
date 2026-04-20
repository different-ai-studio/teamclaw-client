import SwiftUI
import AMUXCore
import AMUXSharedUI

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
            ConnectionBanner(
                state: .from(
                    connectionState: mqtt.connectionState,
                    daemonOnline: connectionMonitor.daemonOnline
                ),
                onReconnect: onReconnect
            )
            Spacer(minLength: 0)
        }
        .allowsHitTesting(mqtt.connectionState == .disconnected)
    }
}
