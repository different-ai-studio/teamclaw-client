import Testing
import Foundation
import AMUXCore
@testable import AMUXMacUI

@Suite("KeychainCredentialStore", .serialized)
struct KeychainCredentialStoreTests {

    private static let testService = "tech.teamclaw.mac.tests"
    private static let testAccount = "pairing-test"

    private func makeStore() -> KeychainCredentialStore {
        let store = KeychainCredentialStore(service: Self.testService, account: Self.testAccount)
        try? store.clear()
        return store
    }

    @Test("load returns nil when keychain has no entry")
    func loadEmpty() throws {
        let store = makeStore()
        #expect(try store.load() == nil)
    }

    @Test("save then load roundtrips all fields")
    func roundtrip() throws {
        let store = makeStore()
        let credentials = PairingCredentials(
            brokerHost: "broker.example.com",
            brokerPort: 8883,
            useTLS: true,
            username: "u",
            password: "p",
            deviceId: "mac-1",
            authToken: "tok-abc"
        )
        try store.save(credentials)
        let loaded = try store.load()
        #expect(loaded == credentials)
    }

    @Test("save replaces a previously stored value")
    func overwrite() throws {
        let store = makeStore()
        let first = PairingCredentials(brokerHost: "h1", brokerPort: 1, useTLS: false, username: "", password: "", deviceId: "d1", authToken: "t1")
        let second = PairingCredentials(brokerHost: "h2", brokerPort: 2, useTLS: true, username: "u", password: "p", deviceId: "d2", authToken: "t2")
        try store.save(first)
        try store.save(second)
        #expect(try store.load() == second)
    }

    @Test("clear removes the entry")
    func clearRemoves() throws {
        let store = makeStore()
        let credentials = PairingCredentials(brokerHost: "h", brokerPort: 8883, useTLS: true, username: "", password: "", deviceId: "d", authToken: "t")
        try store.save(credentials)
        try store.clear()
        #expect(try store.load() == nil)
    }
}
