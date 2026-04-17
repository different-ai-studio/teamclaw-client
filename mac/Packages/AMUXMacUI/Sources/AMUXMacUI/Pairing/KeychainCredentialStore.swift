import Foundation
import Security
import AMUXCore

// @unchecked Sendable is safe: SecItem* APIs are thread-safe per Apple documentation, and this class holds no mutable state beyond immutable let properties (service, account).
public final class KeychainCredentialStore: CredentialStore, @unchecked Sendable {
    private let service: String
    private let account: String

    public init(service: String = "tech.teamclaw.mac", account: String = "default") {
        self.service = service
        self.account = account
    }

    public func save(_ credentials: PairingCredentials) throws {
        let data = try JSONEncoder().encode(StoredCredentials(credentials))
        var query = baseQuery
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            query.merge(attributes) { _, new in new }
            let addStatus = SecItemAdd(query as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.osStatus(addStatus) }
        } else if updateStatus != errSecSuccess {
            throw KeychainError.osStatus(updateStatus)
        }
    }

    public func load() throws -> PairingCredentials? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.osStatus(status) }
        guard let data = item as? Data else { return nil }
        let stored = try JSONDecoder().decode(StoredCredentials.self, from: data)
        return stored.credentials
    }

    public func clear() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.osStatus(status)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public enum KeychainError: Error, CustomStringConvertible {
        case osStatus(OSStatus)
        public var description: String {
            switch self {
            case .osStatus(let s): "Keychain error \(s)"
            }
        }
    }

    private struct StoredCredentials: Codable {
        let brokerHost: String
        let brokerPort: Int
        let useTLS: Bool
        let username: String
        let password: String
        let deviceId: String
        let authToken: String

        init(_ c: PairingCredentials) {
            self.brokerHost = c.brokerHost
            self.brokerPort = c.brokerPort
            self.useTLS = c.useTLS
            self.username = c.username
            self.password = c.password
            self.deviceId = c.deviceId
            self.authToken = c.authToken
        }

        var credentials: PairingCredentials {
            PairingCredentials(
                brokerHost: brokerHost,
                brokerPort: brokerPort,
                useTLS: useTLS,
                username: username,
                password: password,
                deviceId: deviceId,
                authToken: authToken
            )
        }
    }
}
