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

    private let store: CredentialStore

    public init(store: CredentialStore = UserDefaultsCredentialStore()) {
        self.store = store
        loadFromStore()
    }

    public func pair(from url: URL) throws {
        let credentials = try Self.parse(url: url)
        apply(credentials)
        try store.save(credentials)
    }

    public func unpair() throws {
        isPaired = false
        brokerHost = ""
        brokerPort = 8883
        username = ""
        password = ""
        deviceId = ""
        authToken = ""
        useTLS = true
        try store.clear()
    }

    private func apply(_ c: PairingCredentials) {
        brokerHost = c.brokerHost
        brokerPort = c.brokerPort
        useTLS = c.useTLS
        username = c.username
        password = c.password
        deviceId = c.deviceId
        authToken = c.authToken
        isPaired = true
    }

    private func loadFromStore() {
        if let c = try? store.load() {
            apply(c)
        }
    }

    public static func parse(url: URL) throws -> PairingCredentials {
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
        return PairingCredentials(
            brokerHost: host,
            brokerPort: port,
            useTLS: tls,
            username: params["username"] ?? "",
            password: params["password"] ?? "",
            deviceId: device,
            authToken: token
        )
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
