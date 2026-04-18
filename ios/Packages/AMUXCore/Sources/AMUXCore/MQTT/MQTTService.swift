import Foundation
import Observation
import CocoaMQTT

public enum ConnectionState: String, Sendable {
    case disconnected, connecting, connected, reconnecting
}

public struct MQTTIncoming: Sendable {
    public let topic: String
    public let payload: Data
    public let retained: Bool
}

@Observable
public final class MQTTService: NSObject, @unchecked Sendable {
    public private(set) var connectionState: ConnectionState = .disconnected
    private var mqtt: CocoaMQTT?

    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<MQTTIncoming>.Continuation] = [:]
    private var connectContinuation: CheckedContinuation<Void, Error>?

    public override init() { super.init() }

    public func connect(
        host: String, port: Int,
        username: String, password: String,
        clientId: String, useTLS: Bool
    ) async throws {
        connectionState = .connecting

        let mqtt = CocoaMQTT(clientID: clientId, host: host, port: UInt16(port))
        mqtt.username = username
        mqtt.password = password
        mqtt.keepAlive = 90
        mqtt.enableSSL = useTLS
        mqtt.allowUntrustCACertificate = true
        mqtt.delegate = self
        self.mqtt = mqtt

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.connectContinuation = continuation
            let ok = mqtt.connect()
            if !ok {
                self.connectContinuation = nil
                continuation.resume(throwing: MQTTConnectionError.connectFailed)
            }
        }
    }

    public func disconnect() async {
        mqtt?.disconnect()
        mqtt = nil
        connectionState = .disconnected
        lock.lock()
        for (_, c) in continuations { c.finish() }
        continuations.removeAll()
        lock.unlock()
    }

    public func subscribe(_ topic: String) async throws {
        mqtt?.subscribe(topic, qos: .qos1)
    }

    public func publish(topic: String, payload: Data, retain: Bool = false) async throws {
        let message = CocoaMQTTMessage(topic: topic, payload: [UInt8](payload), qos: .qos1, retained: retain)
        mqtt?.publish(message)
    }

    public func messages() -> AsyncStream<MQTTIncoming> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<MQTTIncoming>.makeStream()
        lock.lock()
        continuations[id] = continuation
        lock.unlock()
        continuation.onTermination = { _ in
            self.lock.lock()
            self.continuations.removeValue(forKey: id)
            self.lock.unlock()
        }
        return stream
    }

    private func broadcast(_ msg: MQTTIncoming) {
        lock.lock()
        let conts = Array(continuations.values)
        lock.unlock()
        for c in conts {
            c.yield(msg)
        }
    }

    enum MQTTConnectionError: Error, LocalizedError {
        case connectFailed
        case timeout
        var errorDescription: String? {
            switch self {
            case .connectFailed: "MQTT connection initiation failed"
            case .timeout: "MQTT connection timed out"
            }
        }
    }
}

// MARK: - CocoaMQTTDelegate

extension MQTTService: CocoaMQTTDelegate {
    public func mqtt(_ mqtt: CocoaMQTT, didConnectAck ack: CocoaMQTTConnAck) {
        if ack == .accept {
            connectionState = .connected
            connectContinuation?.resume()
        } else {
            connectionState = .disconnected
            connectContinuation?.resume(throwing: MQTTConnectionError.connectFailed)
        }
        connectContinuation = nil
    }

    public func mqtt(_ mqtt: CocoaMQTT, didPublishMessage message: CocoaMQTTMessage, id: UInt16) {}
    public func mqtt(_ mqtt: CocoaMQTT, didPublishAck id: UInt16) {}

    public func mqtt(_ mqtt: CocoaMQTT, didReceiveMessage message: CocoaMQTTMessage, id: UInt16) {
        let incoming = MQTTIncoming(
            topic: message.topic,
            payload: Data(message.payload),
            retained: message.retained
        )
        broadcast(incoming)
    }

    public func mqtt(_ mqtt: CocoaMQTT, didSubscribeTopics success: NSDictionary, failed: [String]) {}
    public func mqtt(_ mqtt: CocoaMQTT, didUnsubscribeTopics topics: [String]) {}

    public func mqttDidPing(_ mqtt: CocoaMQTT) {}
    public func mqttDidReceivePong(_ mqtt: CocoaMQTT) {}

    public func mqttDidDisconnect(_ mqtt: CocoaMQTT, withError err: (any Error)?) {
        let wasConnecting = connectContinuation != nil
        connectionState = .disconnected
        if wasConnecting, let continuation = connectContinuation {
            connectContinuation = nil
            continuation.resume(throwing: err ?? MQTTConnectionError.connectFailed)
        }
    }

    public func mqtt(_ mqtt: CocoaMQTT, didStateChangeTo state: CocoaMQTTConnState) {}
    public func mqtt(_ mqtt: CocoaMQTT, didReceive trust: SecTrust, completionHandler: @escaping (Bool) -> Void) {
        completionHandler(true)
    }
}
