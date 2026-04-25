# EMQX JWT Phase 4 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace static MQTT credentials with Supabase JWT on both daemon and iOS, and flatten the daemon's two-level reconnect loop.

**Architecture:** EMQX validates the JWT (RS256 via JWKS) placed in the MQTT password field. iOS calls `client.auth.session.accessToken` before each `mqtt.connect()` — supabase-swift auto-refreshes near-expired tokens. The daemon's two-level `'outer`/`'inner` + `tokio::select!` reconnect loop is replaced with a single flat loop; the proactive token-monitor task and its oneshot channel are removed entirely.

**Tech Stack:** rumqttc 0.24 (Rust) · supabase-swift 2.43.1 (iOS) · CocoaMQTT (iOS MQTT client) · EMQX Dashboard (manual)

---

## File Map

| Status | Path | Change |
|--------|------|--------|
| Modify | `daemon/src/daemon/server.rs` | Remove token-monitor + oneshot, flatten event loop |
| Modify | `ios/Packages/AMUXCore/Sources/AMUXCore/Onboarding/AppOnboardingCoordinator.swift` | Add `accessToken()` method |
| Modify | `ios/Packages/AMUXCore/Sources/AMUXCore/Onboarding/SupabaseAppOnboardingStore.swift` | Implement `accessToken()` |
| Modify | `ios/Packages/AMUXCore/Sources/AMUXCore/CredentialStore.swift` | Remove `username`/`password` fields from `PairingCredentials` |
| Modify | `ios/Packages/AMUXCore/Sources/AMUXCore/PairingManager.swift` | Remove `username`/`password` properties and related methods |
| Modify | `ios/Packages/AMUXUI/Sources/AMUXUI/Settings/SettingsView.swift` | Remove Username/Password rows and state |
| Modify | `ios/AMUXApp/ContentView.swift` | Use JWT in `connectMQTT()`, add `accessToken()` to `FailingOnboardingStore` |

---

## Task 1: Simplify daemon reconnect loop

**Files:**
- Modify: `daemon/src/daemon/server.rs`

- [ ] **Step 1.1: Remove unused imports**

In `daemon/src/daemon/server.rs`, replace:
```rust
use std::time::{Duration, Instant};
use tokio::sync::oneshot;
```
With:
```rust
use std::time::Duration;
```

- [ ] **Step 1.2: Replace the two-level loop with a flat loop**

Locate the `pub async fn run(mut self)` method. The section to replace starts at the `let mut first_connect = true;` line and ends at the closing `}` of the outer `'outer: loop`. Replace everything from `let mut first_connect = true;` through `}` (end of outer loop, inclusive) with:

```rust
        let mut first_connect = true;

        'outer: loop {
            // ── 1. Get fresh access_token (retry indefinitely on Supabase errors) ──
            let token = loop {
                match self.supabase.access_token().await {
                    Ok(t) => break t,
                    Err(e) => {
                        warn!("token fetch failed: {e}, retrying in 30s");
                        tokio::time::sleep(Duration::from_secs(30)).await;
                    }
                }
            };

            // ── 2. Rebuild MqttClient ──
            info!(
                actor_id = %self.actor_id,
                broker   = %self.config.mqtt.broker_url,
                "MQTT connecting with access_token"
            );
            self.mqtt = match MqttClient::new(&self.config, &self.actor_id, &token) {
                Ok(c) => c,
                Err(e) => {
                    warn!("MqttClient build failed: {e}, retrying in 5s");
                    tokio::time::sleep(Duration::from_secs(5)).await;
                    continue 'outer;
                }
            };

            // ── 3. Rebuild teamclaw with new AsyncClient ──
            if let Some(team_id) = self.config.team_id.clone() {
                self.teamclaw = match crate::teamclaw::SessionManager::new(
                    self.mqtt.client.clone(),
                    &team_id,
                    &self.config.device.id,
                    Some(self.actor_id.clone()),
                    crate::config::DaemonConfig::config_dir(),
                ) {
                    Ok(tc) => Some(tc),
                    Err(e) => {
                        warn!("teamclaw rebuild failed: {e}");
                        None
                    }
                };
            }

            // ── 4. Wait for CONNACK ──
            loop {
                match self.mqtt.eventloop.poll().await {
                    Ok(Event::Incoming(Packet::ConnAck(_))) => {
                        info!("MQTT CONNACK received");
                        break;
                    }
                    Ok(_) => {}
                    Err(rumqttc::ConnectionError::ConnectionRefused(_)) => {
                        warn!("MQTT connection refused during connect, refreshing token");
                        tokio::time::sleep(Duration::from_secs(3)).await;
                        continue 'outer;
                    }
                    Err(e) => {
                        warn!("MQTT connect error: {e}, retrying...");
                        tokio::time::sleep(Duration::from_secs(3)).await;
                    }
                }
            }

            // ── 5. Subscribe and announce ──
            if let Err(e) = self.mqtt.subscribe_all().await {
                warn!("subscribe_all failed after CONNACK: {e}, reconnecting");
                continue 'outer;
            }
            if let Some(tc) = &mut self.teamclaw {
                if let Err(e) = tc.subscribe_all().await {
                    warn!("teamclaw subscribe failed: {e}, reconnecting");
                    continue 'outer;
                }
            }
            {
                let publisher = Publisher::new(&self.mqtt);
                if let Err(e) = publisher.publish_device_state(&crate::proto::amux::DeviceState {
                    online: true,
                    device_name: self.config.device.name.clone(),
                    timestamp: chrono::Utc::now().timestamp(),
                }).await {
                    warn!("publish_device_state failed after CONNACK: {e}, reconnecting");
                    continue 'outer;
                }
            }
            self.publish_all_agent_states().await;
            info!(device_id = %self.config.device.id, "MQTT connected, listening for commands");

            if first_connect {
                self.register_startup_workspace().await;
                first_connect = false;
            }

            // ── 6. Event loop ──
            loop {
                let agent_events = self.agents.poll_events();
                for (agent_id, acp_event) in agent_events {
                    self.forward_agent_event(&agent_id, acp_event).await;
                }

                match tokio::time::timeout(
                    Duration::from_millis(50),
                    self.mqtt.eventloop.poll(),
                ).await {
                    Ok(Ok(Event::Incoming(Packet::ConnAck(_)))) => {
                        // Network blip — rumqttc reconnected automatically.
                        info!("MQTT reconnected (network blip), re-publishing state");
                        let _ = self.mqtt.subscribe_all().await;
                        if let Some(tc) = &mut self.teamclaw {
                            let _ = tc.subscribe_all().await;
                        }
                        let publisher = Publisher::new(&self.mqtt);
                        let _ = publisher.publish_device_state(&crate::proto::amux::DeviceState {
                            online: true,
                            device_name: self.config.device.name.clone(),
                            timestamp: chrono::Utc::now().timestamp(),
                        }).await;
                        self.publish_all_agent_states().await;
                    }
                    Ok(Ok(Event::Incoming(Packet::Publish(publish)))) => {
                        if let Some(msg) = subscriber::parse_incoming(&publish) {
                            self.handle_incoming(msg).await;
                        }
                    }
                    // EMQX rejected connection (JWT expired).
                    Ok(Err(rumqttc::ConnectionError::ConnectionRefused(_))) => {
                        warn!("MQTT connection refused (token expired), reconnecting");
                        break; // outer loop gets fresh token
                    }
                    Ok(Err(e)) => {
                        warn!("MQTT transient error: {e}, will retry (rumqttc auto-reconnects)");
                        tokio::time::sleep(Duration::from_secs(5)).await;
                    }
                    Ok(Ok(_)) | Err(_) => {} // other events or 50 ms timeout
                }
            }
            // loop exited → outer: get fresh token and reconnect
        }
```

- [ ] **Step 1.3: Build the daemon**

```bash
cd daemon && cargo build 2>&1 | tail -30
```

Expected: compiles with zero errors. Warnings about unused variables (if any) are acceptable.

- [ ] **Step 1.4: Commit**

```bash
git add daemon/src/daemon/server.rs
git commit -m "refactor(daemon): flatten MQTT reconnect loop, remove token-monitor task

Generated with [Claude Code](https://claude.ai/code)
via [Happy](https://happy.engineering)

Co-Authored-By: Claude <noreply@anthropic.com>
Co-Authored-By: Happy <yesreply@happy.engineering>"
```

---

## Task 2: Add `accessToken()` to iOS onboarding protocol and implementations

**Files:**
- Modify: `ios/Packages/AMUXCore/Sources/AMUXCore/Onboarding/AppOnboardingCoordinator.swift`
- Modify: `ios/Packages/AMUXCore/Sources/AMUXCore/Onboarding/SupabaseAppOnboardingStore.swift`

- [ ] **Step 2.1: Add `accessToken()` to the `AppOnboardingStore` protocol**

In `ios/Packages/AMUXCore/Sources/AMUXCore/Onboarding/AppOnboardingCoordinator.swift`, add to the `AppOnboardingStore` protocol after the `handleAuthCallback` line:

Replace:
```swift
    func handleAuthCallback(url: URL) async throws
}
```
With:
```swift
    func handleAuthCallback(url: URL) async throws
    func accessToken() async throws -> String
}
```

- [ ] **Step 2.2: Add `accessToken()` forwarding method to `AppOnboardingCoordinator`**

In the same file, inside `AppOnboardingCoordinator`, add after the `handleAuthCallback` method:

Replace:
```swift
    public func handleAuthCallback(url: URL) async {
```
With:
```swift
    public func accessToken() async throws -> String {
        try await store.accessToken()
    }

    public func handleAuthCallback(url: URL) async {
```

- [ ] **Step 2.3: Implement `accessToken()` in `SupabaseAppOnboardingStore`**

In `ios/Packages/AMUXCore/Sources/AMUXCore/Onboarding/SupabaseAppOnboardingStore.swift`, add after `handleAuthCallback`:

Replace:
```swift
    public func handleAuthCallback(url: URL) async throws {
        _ = try await client.auth.session(from: url)
    }
}
```
With:
```swift
    public func handleAuthCallback(url: URL) async throws {
        _ = try await client.auth.session(from: url)
    }

    public func accessToken() async throws -> String {
        try await client.auth.session.accessToken
    }
}
```

- [ ] **Step 2.4: Build the iOS AMUXCore package to verify**

```bash
cd ios && xcodebuild -scheme AMUX -destination 'generic/platform=iOS Simulator' build 2>&1 | grep -E "error:|Build succeeded|Build FAILED" | head -20
```

Expected: no `error:` lines related to `accessToken`.

- [ ] **Step 2.5: Commit**

```bash
git add ios/Packages/AMUXCore/Sources/AMUXCore/Onboarding/AppOnboardingCoordinator.swift \
        ios/Packages/AMUXCore/Sources/AMUXCore/Onboarding/SupabaseAppOnboardingStore.swift
git commit -m "feat(ios): add accessToken() to onboarding store protocol and coordinator

Generated with [Claude Code](https://claude.ai/code)
via [Happy](https://happy.engineering)

Co-Authored-By: Claude <noreply@anthropic.com>
Co-Authored-By: Happy <yesreply@happy.engineering>"
```

---

## Task 3: Strip static credentials from PairingCredentials, PairingManager, SettingsView

**Files:**
- Modify: `ios/Packages/AMUXCore/Sources/AMUXCore/CredentialStore.swift`
- Modify: `ios/Packages/AMUXCore/Sources/AMUXCore/PairingManager.swift`
- Modify: `ios/Packages/AMUXUI/Sources/AMUXUI/Settings/SettingsView.swift`

- [ ] **Step 3.1: Remove `username` and `password` from `PairingCredentials`**

In `ios/Packages/AMUXCore/Sources/AMUXCore/CredentialStore.swift`, replace the struct:

```swift
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
```
With:
```swift
public struct PairingCredentials: Equatable, Sendable {
    public var brokerHost: String
    public var brokerPort: Int
    public var useTLS: Bool
    public var deviceId: String
    public var authToken: String

    public init(
        brokerHost: String,
        brokerPort: Int,
        useTLS: Bool,
        deviceId: String,
        authToken: String
    ) {
        self.brokerHost = brokerHost
        self.brokerPort = brokerPort
        self.useTLS = useTLS
        self.deviceId = deviceId
        self.authToken = authToken
    }
}
```

- [ ] **Step 3.2: Remove `username`/`password` keys from `UserDefaultsCredentialStore`**

In the same file, replace `UserDefaultsCredentialStore`:

```swift
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
            deviceId: defaults.string(forKey: Keys.deviceId) ?? "",
            authToken: defaults.string(forKey: Keys.authToken) ?? ""
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
```
With:
```swift
public final class UserDefaultsCredentialStore: CredentialStore, @unchecked Sendable {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func save(_ c: PairingCredentials) throws {
        defaults.set(c.brokerHost, forKey: Keys.brokerHost)
        defaults.set(c.brokerPort, forKey: Keys.brokerPort)
        defaults.set(c.deviceId, forKey: Keys.deviceId)
        defaults.set(c.authToken, forKey: Keys.authToken)
        defaults.set(c.useTLS, forKey: Keys.useTLS)
    }

    public func load() throws -> PairingCredentials? {
        guard let host = defaults.string(forKey: Keys.brokerHost),
              !host.isEmpty else {
            return nil
        }
        var port = defaults.integer(forKey: Keys.brokerPort)
        if port == 0 { port = 8883 }
        return PairingCredentials(
            brokerHost: host,
            brokerPort: port,
            useTLS: defaults.bool(forKey: Keys.useTLS),
            deviceId: defaults.string(forKey: Keys.deviceId) ?? "",
            authToken: defaults.string(forKey: Keys.authToken) ?? ""
        )
    }

    public func clear() throws {
        for key in Keys.all { defaults.removeObject(forKey: key) }
    }

    private enum Keys {
        static let brokerHost = "amux_broker_host"
        static let brokerPort = "amux_broker_port"
        static let deviceId   = "amux_device_id"
        static let authToken  = "amux_auth_token"
        static let useTLS     = "amux_use_tls"
        static let all = [brokerHost, brokerPort, deviceId, authToken, useTLS]
    }
}
```

- [ ] **Step 3.3: Remove `username`/`password` from `PairingManager`**

In `ios/Packages/AMUXCore/Sources/AMUXCore/PairingManager.swift`, replace the entire file contents with:

```swift
import Foundation
import Observation

@Observable
public final class PairingManager {
    public private(set) var isPaired: Bool = false
    public private(set) var brokerHost: String = ""
    public private(set) var brokerPort: Int = 8883
    public private(set) var deviceId: String = ""
    public private(set) var authToken: String = ""
    public private(set) var useTLS: Bool = true

    private let store: CredentialStore

    public init(store: CredentialStore = UserDefaultsCredentialStore()) {
        self.store = store
        loadFromStore()
        if brokerHost.isEmpty {
            applyDefaults()
        }
    }

    /// Legacy MQTT pairing deeplink flow. iOS no longer invokes this — use
    /// `updateMQTTServer(...)` via Settings instead. Kept for the macOS shell
    /// which still presents a paste-a-deeplink UI.
    public func pair(from url: URL) throws {
        let credentials = try Self.parse(url: url)
        try store.save(credentials)
        apply(credentials)
    }

    public func updateMQTTServer(host: String) throws {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        self.brokerHost = trimmedHost
        self.isPaired = !trimmedHost.isEmpty
        try store.save(currentCredentials())
    }

    public func updateDaemonDeviceID(_ deviceID: String) throws {
        self.deviceId = deviceID.trimmingCharacters(in: .whitespacesAndNewlines)
        try store.save(currentCredentials())
    }

    public func unpair() throws {
        isPaired = false
        brokerHost = ""
        brokerPort = 8883
        deviceId = ""
        authToken = ""
        useTLS = true
        try store.clear()
    }

    private func applyDefaults() {
        let defaults = PairingCredentials(
            brokerHost: "ai.ucar.cc",
            brokerPort: 8883,
            useTLS: true,
            deviceId: deviceId,
            authToken: authToken
        )
        try? store.save(defaults)
        apply(defaults)
    }

    private func apply(_ c: PairingCredentials) {
        brokerHost = c.brokerHost
        brokerPort = c.brokerPort
        useTLS = c.useTLS
        deviceId = c.deviceId
        authToken = c.authToken
        isPaired = !c.brokerHost.isEmpty
    }

    private func currentCredentials() -> PairingCredentials {
        PairingCredentials(
            brokerHost: brokerHost,
            brokerPort: brokerPort,
            useTLS: useTLS,
            deviceId: deviceId,
            authToken: authToken
        )
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
            item.value.map { (item.name, $0.filter { !$0.isWhitespace && !$0.isNewline }) }
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
```

- [ ] **Step 3.4: Remove Username/Password fields from `SettingsView`**

In `ios/Packages/AMUXUI/Sources/AMUXUI/Settings/SettingsView.swift`:

Replace the `@State` fields for mqtt user/pass:
```swift
    @State private var mqttHost: String = ""
    @State private var mqttUser: String = ""
    @State private var mqttPass: String = ""
    @State private var daemonDeviceID: String = ""
```
With:
```swift
    @State private var mqttHost: String = ""
    @State private var daemonDeviceID: String = ""
```

Replace `hasMQTTChanges`:
```swift
    private var hasMQTTChanges: Bool {
        mqttHost != pairing.brokerHost ||
        mqttUser != pairing.username ||
        mqttPass != pairing.password ||
        daemonDeviceID != pairing.deviceId
    }
```
With:
```swift
    private var hasMQTTChanges: Bool {
        mqttHost != pairing.brokerHost ||
        daemonDeviceID != pairing.deviceId
    }
```

Replace the MQTT Section body:
```swift
                Section("MQTT Server") {
                    LabeledField(label: "Host", text: $mqttHost, placeholder: "ai.ucar.cc")
                    LabeledField(label: "Username", text: $mqttUser, placeholder: "teamclaw")
                    LabeledSecureField(label: "Password", text: $mqttPass)
                    LabeledField(label: "Daemon ID", text: $daemonDeviceID, placeholder: "mac-mini-4")
```
With:
```swift
                Section("MQTT Server") {
                    LabeledField(label: "Host", text: $mqttHost, placeholder: "ai.ucar.cc")
                    LabeledField(label: "Daemon ID", text: $daemonDeviceID, placeholder: "mac-mini-4")
```

Replace the `.task` initializer for `mqttUser`/`mqttPass`:
```swift
            .task {
                mqttHost = pairing.brokerHost
                mqttUser = pairing.username
                mqttPass = pairing.password
                daemonDeviceID = pairing.deviceId
```
With:
```swift
            .task {
                mqttHost = pairing.brokerHost
                daemonDeviceID = pairing.deviceId
```

Replace the `save()` call:
```swift
    private func save() {
        do {
            try pairing.updateMQTTServer(host: mqttHost, username: mqttUser, password: mqttPass)
            try pairing.updateDaemonDeviceID(daemonDeviceID)
```
With:
```swift
    private func save() {
        do {
            try pairing.updateMQTTServer(host: mqttHost)
            try pairing.updateDaemonDeviceID(daemonDeviceID)
```

- [ ] **Step 3.5: Build to verify no compile errors**

```bash
cd ios && xcodebuild -scheme AMUX -destination 'generic/platform=iOS Simulator' build 2>&1 | grep -E "error:|Build succeeded|Build FAILED" | head -30
```

Expected: no `error:` lines related to `username`, `password`, or `updateMQTTServer`.

- [ ] **Step 3.6: Commit**

```bash
git add ios/Packages/AMUXCore/Sources/AMUXCore/CredentialStore.swift \
        ios/Packages/AMUXCore/Sources/AMUXCore/PairingManager.swift \
        ios/Packages/AMUXUI/Sources/AMUXUI/Settings/SettingsView.swift
git commit -m "feat(ios): remove static MQTT credentials from PairingCredentials and SettingsView

Generated with [Claude Code](https://claude.ai/code)
via [Happy](https://happy.engineering)

Co-Authored-By: Claude <noreply@anthropic.com>
Co-Authored-By: Happy <yesreply@happy.engineering>"
```

---

## Task 4: Update `ContentView.connectMQTT()` to use JWT

**Files:**
- Modify: `ios/AMUXApp/ContentView.swift`

- [ ] **Step 4.1: Add `accessToken()` to `FailingOnboardingStore`**

In `ios/AMUXApp/ContentView.swift`, add to `FailingOnboardingStore`:

Replace:
```swift
    func handleAuthCallback(url: URL) async throws { throw error }
}
```
With:
```swift
    func handleAuthCallback(url: URL) async throws { throw error }
    func accessToken() async throws -> String { throw error }
}
```

- [ ] **Step 4.2: Update `connectMQTT()` to fetch JWT and use it as password**

Replace the entire `connectMQTT()` method:
```swift
    private func connectMQTT() async {
        guard onboarding.route == .ready, pairing.isPaired, !isConnecting else { return }
        isConnecting = true
        defer { isConnecting = false }
        logger.info("Connecting to \(pairing.brokerHost):\(pairing.brokerPort) tls=\(pairing.useTLS) user=\(pairing.username)")
        do {
            logger.info("Calling mqtt.connect()...")
            let clientId = "amux-ios-\(pairing.authToken.prefix(8))"
            try await mqtt.connect(host: pairing.brokerHost, port: pairing.brokerPort,
                username: pairing.username, password: pairing.password,
                clientId: clientId, useTLS: pairing.useTLS)
            logger.info("mqtt.connect() returned successfully")

            // Legacy PeerAnnounce publish on device/{id}/collab was retired in
            // Phase 3 — the daemon no longer subscribes to that topic. Broker-
            // level JWT auth now handles peer authentication; peer presence is
            // driven by `device/{id}/peers` retained state published by the
            // daemon.
            logger.info("MQTT connected")

            // Start TeamclawService for work items and collab sessions
            teamclawService.start(
                mqtt: mqtt,
                teamId: onboarding.currentContext?.team.id ?? "",
                deviceId: pairing.deviceId,
                peerId: "ios-\(pairing.authToken.prefix(6))",
                modelContext: modelContext
            )
        } catch {
            logger.error("MQTT connect failed: \(error)")
        }
    }
```
With:
```swift
    private func connectMQTT() async {
        guard onboarding.route == .ready, pairing.isPaired, !isConnecting else { return }
        isConnecting = true
        defer { isConnecting = false }

        let token: String
        do {
            token = try await onboarding.accessToken()
        } catch {
            logger.error("Failed to get access token for MQTT: \(error)")
            return
        }

        let userID = onboarding.currentContext?.memberActorID ?? "amux-ios"
        let clientId = "amux-ios-\(userID.prefix(8))"
        logger.info("Connecting to \(pairing.brokerHost):\(pairing.brokerPort) tls=\(pairing.useTLS)")
        do {
            try await mqtt.connect(
                host: pairing.brokerHost, port: pairing.brokerPort,
                username: userID, password: token,
                clientId: clientId, useTLS: pairing.useTLS
            )
            logger.info("MQTT connected")

            teamclawService.start(
                mqtt: mqtt,
                teamId: onboarding.currentContext?.team.id ?? "",
                deviceId: pairing.deviceId,
                peerId: "ios-\(userID.prefix(8))",
                modelContext: modelContext
            )
        } catch {
            logger.error("MQTT connect failed: \(error)")
        }
    }
```

- [ ] **Step 4.3: Build to verify no compile errors**

```bash
cd ios && xcodebuild -scheme AMUX -destination 'generic/platform=iOS Simulator' build 2>&1 | grep -E "error:|Build succeeded|Build FAILED" | head -30
```

Expected: `Build succeeded`

- [ ] **Step 4.4: Commit**

```bash
git add ios/AMUXApp/ContentView.swift
git commit -m "feat(ios): use Supabase JWT as MQTT password, drop static credentials

Generated with [Claude Code](https://claude.ai/code)
via [Happy](https://happy.engineering)

Co-Authored-By: Claude <noreply@anthropic.com>
Co-Authored-By: Happy <yesreply@happy.engineering>"
```

---

## Task 5: EMQX Dashboard configuration (manual)

This task has no code — it documents the manual steps to switch EMQX to JWT-only auth.

> **Important:** Complete Tasks 1–4 (deploy daemon + iOS) BEFORE doing this step. Once the static password authenticator is removed, old daemon/iOS builds can no longer connect.

- [ ] **Step 5.1: Open EMQX Dashboard**

Navigate to the EMQX Dashboard web UI for the deployment (broker host `ai.ucar.cc`).

- [ ] **Step 5.2: Add JWT authenticator**

Go to **Access Control → Authentication → Create**.

Configure:
- **Mechanism**: JWT
- **Algorithm**: JWKS (asymmetric, key set fetched from URL). EMQX picks the
  signing alg from the JWT's `kid`/JWKS — Supabase currently uses **ES256**,
  not RSA. Do not pin RS256.
- **JWKS Endpoint**: `https://srhaytajyfrniuvnkfpd.supabase.co/auth/v1/.well-known/jwks.json`
- **JWKS connector → SSL/TLS: ENABLED**, `verify: verify_none`. Required —
  EMQX's per-authenticator HTTP client defaults to `ssl.enable: false`,
  which silently returns an empty JWKS for `https://` URLs and makes every
  JWT fail with `invalid_jwt_signature`. (Verifiable via REST:
  `GET /api/v5/authentication/jwt` should show `ssl.enable: true`.)
- **JWT From**: `password` (the MQTT password field; username carries the
  actor_id and is not parsed as a JWT)
- **Disconnect After Expire**: disabled (off)
- **ACL Claim Name**: `acl` (consumed from the access-token hook)
- **Verify Claims**: leave empty (Supabase's `aud: authenticated` is fine;
  pinning `iss` adds no security since the JWKS is already issuer-scoped)

Save.

- [ ] **Step 5.3: Reorder the authenticator chain — JWT first**

In the Authentication list, drag the JWT authenticator above the
Password-Based one (REST equivalent:
`PUT /api/v5/authentication/jwt/position/front`). With the static
authenticator running first, every JWT-as-password results in `ignore`
from password-based and the chain ends in `not_authorized` regardless of
JWT validity. JWT-first is required during the dual-authenticator window.

- [ ] **Step 5.4: Delete the Password authenticator**

In the Authentication list, find the existing Password-Based authenticator (user `teamclaw`). Delete it.

- [ ] **Step 5.5: Smoke-test with current daemon**

Run the daemon on the developer machine:

```bash
cd daemon && cargo run -- start
```

Expected log output within 10 seconds:
```
INFO MQTT CONNACK received
INFO MQTT connected, listening for commands
```

**Troubleshooting** — if the daemon loops on
`MQTT connection refused during connect, refreshing token reason=NotAuthorized`,
inspect the authenticator's metrics first:

```
GET /api/v5/authentication/jwt/status
```

If `nomatch` is incrementing while `success` and `failed` stay at 0, EMQX
is rejecting the token without ever validating it. Open a trace
(`POST /api/v5/trace`, type `clientid`, the daemon's clientid is
`amuxd-<first 8 chars of device.id>`) and read the `[AUTHN]` line. A line
shaped like `msg: invalid_jwt_signature, jwks: ` (empty after `jwks:`)
means the JWKS fetch failed — almost always because step 5.2's SSL toggle
was missed. A non-empty `jwks:` value with `invalid_jwt_signature` means
the JWT header's `kid` doesn't match any key in the JWKS (likely a stale
JWKS cache; bump `refresh_interval` or reload the authenticator).

- [ ] **Step 5.6: Smoke-test with iOS**

Launch the iOS app on a device or simulator connected to the same broker. Navigate to Sessions tab.

Expected: sessions load, daemon is shown as online.
