# EMQX JWT Phase 4 Design

Date: 2026-04-25

## Goal

Replace static MQTT credentials (`teamclaw`/`teamclaw2026`) with Supabase JWT across iOS and daemon, and switch EMQX to JWT-only authentication using the existing JWKS endpoint.

## Fixed Decisions

- Hard cutover: static password authenticator removed at the same time JWT is enabled; no dual-mode period
- `disconnect_after_expire = false`: EMQX does not forcibly kick connected clients when their JWT expires — lazy reconnect on next natural disconnect is sufficient
- JWT goes in the MQTT **password** field; any non-empty username is acceptable (use Supabase `member_actor_id`)
- Daemon simplification: the two-level `'outer`/`'inner` loop with a proactive token-monitor timer is designed for `disconnect_after_expire = true` (proactive kick before expiry). With `disconnect_after_expire = false` the timer is unnecessary — flatten to a single loop
- No ACL claim injection in Phase 4 (Supabase hook for injecting `acl` into JWT is future work); EMQX topic access control remains open for now

## EMQX Configuration (Manual)

Configure via EMQX Dashboard (web UI). No code required.

### Steps

1. **Authentication → Create → JWT**
   - Algorithm: RS256 (asymmetric, via JWKS)
   - JWKS endpoint: `https://srhaytajyfrniuvnkfpd.supabase.co/auth/v1/.well-known/jwks.json`
   - From: `password` (JWT in MQTT password field)
   - `disconnect_after_expire`: disabled (false)

2. **Delete the existing Password authenticator** (`teamclaw` / `teamclaw2026`)

3. Verify: connect a test MQTT client with a valid Supabase access token as password; confirm connection accepted.

## iOS Changes

### AppOnboardingStore protocol

Add one method:

```swift
func accessToken() async throws -> String
```

### SupabaseAppOnboardingStore

Implement by returning the current Supabase session token (auto-refreshes if expired):

```swift
public func accessToken() async throws -> String {
    try await client.auth.session.accessToken
}
```

### AppOnboardingCoordinator

Expose the method as a `@MainActor` async forward:

```swift
public func accessToken() async throws -> String {
    try await store.accessToken()
}
```

### ContentView.connectMQTT()

Fetch a fresh JWT before each `mqtt.connect()` call:

```swift
let token = try await onboarding.accessToken()
let userID = onboarding.currentContext?.memberActorID ?? "amux-ios"
let clientId = "amux-ios-\(userID.prefix(8))"
try await mqtt.connect(
    host: pairing.brokerHost, port: pairing.brokerPort,
    username: userID,
    password: token,
    clientId: clientId,
    useTLS: pairing.useTLS
)
```

Since `onboarding.accessToken()` calls `client.auth.session`, the supabase-swift SDK automatically refreshes the token if it is near expiry — no timer needed.

### PairingCredentials / PairingManager / SettingsView

Remove `username` and `password` from:
- `PairingCredentials` struct
- `PairingManager` properties + `updateMQTTServer()` signature + `applyDefaults()`
- `UserDefaultsCredentialStore` save/load/Keys
- `SettingsView` state fields + `hasMQTTChanges` + `save()` call
- `SettingsView` MQTT section rows (remove Username and Password fields)

Keep: `brokerHost`, `brokerPort`, `useTLS`, `deviceId`, `authToken` (authToken is still used for client ID derivation and peer ID).

## Daemon Changes

### server.rs imports

Remove `Instant` (used only in expiry calculation) and `oneshot`:

```rust
// Before
use std::time::{Duration, Instant};
use tokio::sync::oneshot;

// After
use std::time::Duration;
```

### DaemonServer::run() — flatten the reconnect loop

Current: two-level `'outer`/`'inner` loop where:
- `'outer` gets a token and builds the client
- The token-monitor task fires a oneshot ~5 min before JWT expiry
- `'inner` uses `tokio::select!` across the oneshot and MQTT poll

New: single labeled loop. Remove token-monitor task, oneshot channel, `tokio::select!`, and the post-inner-loop drain:

```
'outer: loop {
    // 1. Get fresh token (same)
    // 2. Rebuild MqttClient (same)
    // 3. Rebuild teamclaw (same)
    // 4. Wait for CONNACK (same)
    // 5. Subscribe + announce (same)
    // 6. Event loop — flat match, no select!
    loop {
        // drain agent events
        match timeout(50ms, eventloop.poll()).await {
            ConnAck  → re-subscribe + republish (network blip)
            Publish  → handle_incoming
            ConnectionRefused → break  // EMQX rejected JWT; outer loop gets new token
            transient error   → sleep 5s
            timeout  → continue
        }
    }
    // loop exited → outer: get fresh token and reconnect
}
```

Drop the post-inner drain loop (it was only needed to flush a proactive DISCONNECT packet before dropping the eventloop; no proactive disconnect in the new design).

## Rollout Order

1. Build and deploy new daemon (JWT MQTT connect, simplified loop)
2. Build and deploy new iOS app (JWT MQTT connect, no static credentials)
3. Switch EMQX to JWT-only auth (delete password authenticator, add JWT authenticator)
4. Smoke-test: daemon connects, iOS connects, events flow
