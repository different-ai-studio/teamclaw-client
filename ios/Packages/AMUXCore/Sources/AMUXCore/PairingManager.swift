import Foundation
import Observation

@Observable
public final class PairingManager {
    public private(set) var isPaired: Bool = false
    public private(set) var brokerHost: String = ""
    public private(set) var brokerPort: Int = 8883
    public private(set) var username: String = ""
    public private(set) var password: String = ""
    public private(set) var deviceId: String = ""
    public private(set) var authToken: String = ""
    public private(set) var useTLS: Bool = true

    private let defaults = UserDefaults.standard

    public init() {
        loadSaved()
    }

    public func pair(from url: URL) throws {
        guard url.scheme == "amux", url.host == "join" else {
            throw PairingError.invalidURL
        }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems else {
            throw PairingError.invalidURL
        }

        let params = Dictionary(uniqueKeysWithValues: items.compactMap { item in
            item.value.map { (item.name, $0) }
        })

        guard let broker = params["broker"],
              let device = params["device"],
              let token = params["token"] else {
            throw PairingError.missingFields
        }

        let tls = broker.hasPrefix("mqtts://")
        let hostPart = broker
            .replacingOccurrences(of: "mqtts://", with: "")
            .replacingOccurrences(of: "mqtt://", with: "")
        let parts = hostPart.split(separator: ":")
        let host = String(parts[0])
        let defaultPort = tls ? 8883 : 1883
        let port = parts.count > 1 ? Int(parts[1]) ?? defaultPort : defaultPort

        let user = params["username"] ?? ""
        let pass = params["password"] ?? ""

        self.brokerHost = host
        self.brokerPort = port
        self.username = user
        self.password = pass
        self.deviceId = device
        self.authToken = token
        self.useTLS = tls
        self.isPaired = true

        save()
    }

    public func unpair() {
        isPaired = false
        brokerHost = ""
        deviceId = ""
        authToken = ""
        for key in ["amux_broker_host", "amux_broker_port", "amux_username", "amux_password", "amux_device_id", "amux_auth_token", "amux_use_tls"] {
            defaults.removeObject(forKey: key)
        }
    }

    private func save() {
        defaults.set(brokerHost, forKey: "amux_broker_host")
        defaults.set(brokerPort, forKey: "amux_broker_port")
        defaults.set(username, forKey: "amux_username")
        defaults.set(password, forKey: "amux_password")
        defaults.set(deviceId, forKey: "amux_device_id")
        defaults.set(authToken, forKey: "amux_auth_token")
        defaults.set(useTLS, forKey: "amux_use_tls")
    }

    @discardableResult
    private func loadSaved() -> Bool {
        guard let host = defaults.string(forKey: "amux_broker_host"),
              let device = defaults.string(forKey: "amux_device_id"),
              let token = defaults.string(forKey: "amux_auth_token"),
              !host.isEmpty else {
            return false
        }
        brokerHost = host
        brokerPort = defaults.integer(forKey: "amux_broker_port")
        if brokerPort == 0 { brokerPort = 8883 }
        username = defaults.string(forKey: "amux_username") ?? ""
        password = defaults.string(forKey: "amux_password") ?? ""
        deviceId = device
        authToken = token
        useTLS = defaults.bool(forKey: "amux_use_tls")
        isPaired = true
        return true
    }

    public enum PairingError: Error, LocalizedError {
        case invalidURL
        case missingFields

        public var errorDescription: String? {
            switch self {
            case .invalidURL: "Invalid pairing URL"
            case .missingFields: "Missing broker, device, or token in URL"
            }
        }
    }
}
