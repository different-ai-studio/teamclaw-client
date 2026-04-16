import SwiftUI
import UIKit
import os
import AMUXCore
import AMUXUI

private let logger = Logger(subsystem: "com.amux.app", category: "MQTT")

struct ContentView: View {
    let pairing: PairingManager
    @State private var mqtt = MQTTService()
    @State private var connectionMonitor = ConnectionMonitor()
    @State private var isConnecting = false

    var body: some View {
        Group {
            if pairing.isPaired {
                SessionListView(mqtt: mqtt, pairing: pairing, connectionMonitor: connectionMonitor)
                    .task { await connectMQTT() }
            } else {
                PairingView(pairing: pairing)
                    .onChange(of: pairing.isPaired) { _, paired in
                        if paired { Task { await connectMQTT() } }
                    }
            }
        }
        .onOpenURL { url in
            logger.info("Received URL: \(url.absoluteString)")
            do {
                try pairing.pair(from: url)
                logger.info("Pairing succeeded, isPaired=\(pairing.isPaired)")
            } catch {
                logger.error("Pairing failed: \(error)")
            }
        }
    }

    private func connectMQTT() async {
        guard pairing.isPaired, !isConnecting else { return }
        isConnecting = true
        defer { isConnecting = false }
        logger.info("Connecting to \(pairing.brokerHost):\(pairing.brokerPort) tls=\(pairing.useTLS) user=\(pairing.username)")
        do {
            logger.info("Calling mqtt.connect()...")
            try await mqtt.connect(host: pairing.brokerHost, port: pairing.brokerPort,
                username: pairing.username, password: pairing.password,
                clientId: "amux-ios-\(UUID().uuidString.prefix(6))", useTLS: pairing.useTLS)
            logger.info("mqtt.connect() returned successfully")

            var cmd = Amux_DeviceCommandEnvelope()
            cmd.deviceID = pairing.deviceId
            cmd.peerID = "ios-\(pairing.authToken.prefix(6))"
            cmd.commandID = UUID().uuidString
            cmd.timestamp = Int64(Date().timeIntervalSince1970)
            var announce = Amux_PeerAnnounce()
            announce.authToken = pairing.authToken
            var peerInfo = Amux_PeerInfo()
            peerInfo.peerID = cmd.peerID
            peerInfo.displayName = UIDevice.current.name
            peerInfo.deviceType = "ios"
            peerInfo.connectedAt = cmd.timestamp
            announce.peer = peerInfo
            var collabCmd = Amux_DeviceCollabCommand()
            collabCmd.command = .peerAnnounce(announce)
            cmd.command = collabCmd
            let data = try ProtoMQTTCoder.encode(cmd)
            try await mqtt.publish(topic: "amux/\(pairing.deviceId)/collab", payload: data)

            // Subscribe to device-level collab topic for rejections, peer events, etc.
            try await mqtt.subscribe("amux/\(pairing.deviceId)/collab")

            logger.info("MQTT connected, PeerAnnounce sent, collab subscribed")
            connectionMonitor.start(mqtt: mqtt, deviceId: pairing.deviceId)
        } catch {
            logger.error("MQTT connect failed: \(error)")
        }
    }
}
