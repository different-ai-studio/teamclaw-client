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

    /// Serialises access to `continuations` and `connectContinuation`.
    /// Previously an `NSLock`, which deadlocked the main thread on back-button
    /// dismiss: `disconnect()` held the lock while finishing each continuation,
    /// `finish()` synchronously invoked the per-continuation `onTermination`
    /// closure, which then tried to re-acquire the non-reentrant `NSLock` on
    /// the same thread → hang (see Sentry TEAMCLAW-IOS-2). A serial dispatch
    /// queue sidesteps the reentrance problem entirely: even if the closure
    /// is invoked on a thread currently waiting on the queue, the cleanup is
    /// dispatched (`async`) and runs after the current work item completes.
    private let stateQueue = DispatchQueue(label: "com.amux.mqtt-service.state")
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

        // Race the CONNACK against a 15 s timeout — without this, a dead
        // socket that never yields a delegate callback would leave the
        // continuation unresumed forever, and the caller-side isConnecting
        // flag with it. Reported symptom: "Not Connected" sticks, tap
        // reconnect does nothing, only kill+relaunch recovers.
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await self.waitForConnectAck(mqtt: mqtt)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(15))
                // Timeout fires: drain the pending continuation so the
                // CONNACK arm (if it ever returns) doesn't try to resume
                // a stale one.
                if let pending = self.takeConnectContinuation() {
                    pending.resume(throwing: MQTTConnectionError.timeout)
                }
                throw MQTTConnectionError.timeout
            }
            try await group.next()
            group.cancelAll()
        }
    }

    private func waitForConnectAck(mqtt: CocoaMQTT) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            // Publish the continuation to state BEFORE calling connect() so
            // a fast CONNACK on the delegate thread finds it installed.
            stateQueue.sync {
                self.connectContinuation = continuation
            }
            let ok = mqtt.connect()
            if !ok {
                if let pending = takeConnectContinuation() {
                    pending.resume(throwing: MQTTConnectionError.connectFailed)
                }
            }
        }
    }

    public func disconnect() async {
        mqtt?.disconnect()
        mqtt = nil
        connectionState = .disconnected
        // Snapshot + drain OUTSIDE the critical section; each `finish()`
        // triggers `onTermination`, which itself dispatches back to the
        // queue — we must not be in the queue when that happens.
        let conts: [AsyncStream<MQTTIncoming>.Continuation] = stateQueue.sync {
            let snapshot = Array(continuations.values)
            continuations.removeAll()
            return snapshot
        }
        for c in conts { c.finish() }
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
        stateQueue.async {
            self.continuations[id] = continuation
        }
        continuation.onTermination = { [weak self] _ in
            // Dispatch async so the cancelling thread (often the main actor
            // during a view-dismiss Task cancellation) never blocks waiting
            // on the queue.
            self?.stateQueue.async {
                self?.continuations.removeValue(forKey: id)
            }
        }
        return stream
    }

    private func broadcast(_ msg: MQTTIncoming) {
        let conts: [AsyncStream<MQTTIncoming>.Continuation] = stateQueue.sync {
            Array(continuations.values)
        }
        for c in conts {
            c.yield(msg)
        }
    }

    /// Atomically consumes `connectContinuation` — ensures only the first
    /// caller (whether the CONNACK delegate, the immediate-false return in
    /// `connect()`, or an unexpected mid-handshake `mqttDidDisconnect`) gets
    /// to resume the stored continuation.
    fileprivate func takeConnectContinuation() -> CheckedContinuation<Void, Error>? {
        stateQueue.sync {
            let c = connectContinuation
            connectContinuation = nil
            return c
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
        let pending = takeConnectContinuation()
        if ack == .accept {
            connectionState = .connected
            pending?.resume()
        } else {
            connectionState = .disconnected
            pending?.resume(throwing: MQTTConnectionError.connectFailed)
        }
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
        connectionState = .disconnected
        if let pending = takeConnectContinuation() {
            pending.resume(throwing: err ?? MQTTConnectionError.connectFailed)
        }
    }

    public func mqtt(_ mqtt: CocoaMQTT, didStateChangeTo state: CocoaMQTTConnState) {}
    public func mqtt(_ mqtt: CocoaMQTT, didReceive trust: SecTrust, completionHandler: @escaping (Bool) -> Void) {
        completionHandler(true)
    }
}
