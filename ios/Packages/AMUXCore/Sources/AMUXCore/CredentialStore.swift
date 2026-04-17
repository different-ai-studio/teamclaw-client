import Foundation

public struct PairingCredentials: Equatable, Sendable {
    public var brokerHost: String
    public var brokerPort: Int
    public var useTLS: Bool
    public var username: String
    public var password: String
    public var deviceId: String
    public var authToken: String

    public init(
        brokerHost: String,
        brokerPort: Int,
        useTLS: Bool,
        username: String,
        password: String,
        deviceId: String,
        authToken: String
    ) {
        self.brokerHost = brokerHost
        self.brokerPort = brokerPort
        self.useTLS = useTLS
        self.username = username
        self.password = password
        self.deviceId = deviceId
        self.authToken = authToken
    }
}

public protocol CredentialStore: AnyObject, Sendable {
    func save(_ credentials: PairingCredentials) throws
    func load() throws -> PairingCredentials?
    func clear() throws
}

public final class UserDefaultsCredentialStore: CredentialStore, @unchecked Sendable {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func save(_ c: PairingCredentials) throws {
        defaults.set(c.brokerHost, forKey: Keys.brokerHost)
        defaults.set(c.brokerPort, forKey: Keys.brokerPort)
        defaults.set(c.username, forKey: Keys.username)
        defaults.set(c.password, forKey: Keys.password)
        defaults.set(c.deviceId, forKey: Keys.deviceId)
        defaults.set(c.authToken, forKey: Keys.authToken)
        defaults.set(c.useTLS, forKey: Keys.useTLS)
    }

    public func load() throws -> PairingCredentials? {
        guard let host = defaults.string(forKey: Keys.brokerHost),
              let device = defaults.string(forKey: Keys.deviceId),
              let token = defaults.string(forKey: Keys.authToken),
              !host.isEmpty else {
            return nil
        }
        var port = defaults.integer(forKey: Keys.brokerPort)
        if port == 0 { port = 8883 }
        return PairingCredentials(
            brokerHost: host,
            brokerPort: port,
            useTLS: defaults.bool(forKey: Keys.useTLS),
            username: defaults.string(forKey: Keys.username) ?? "",
            password: defaults.string(forKey: Keys.password) ?? "",
            deviceId: device,
            authToken: token
        )
    }

    public func clear() throws {
        for key in Keys.all { defaults.removeObject(forKey: key) }
    }

    private enum Keys {
        static let brokerHost = "amux_broker_host"
        static let brokerPort = "amux_broker_port"
        static let username   = "amux_username"
        static let password   = "amux_password"
        static let deviceId   = "amux_device_id"
        static let authToken  = "amux_auth_token"
        static let useTLS     = "amux_use_tls"
        static let all = [brokerHost, brokerPort, username, password, deviceId, authToken, useTLS]
    }
}
