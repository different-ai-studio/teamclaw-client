# iOS New-Session + deviceId Cleanup — Phase 4 Follow-up

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix two iOS gaps that the EMQX JWT Phase 4 cutover surfaced. Both block the same end-to-end flow — sending a prompt from a fresh sign-in to the running daemon and seeing streamed assistant output rendered in the iOS detail view.

**Acceptance:** `AMUXUITests/AMUXSessionStreamingUITests/testNewSessionStreamsAssistantOutput` (added in commit `23088689`) passes against a real daemon with no manual UI driving — sign in, type prompt, tap Send, wait for streamed text.

---

## Background

Until commit `c73ea7f1` ("remove static MQTT credentials from config and invite URL") iOS got its identity from a pairing deeplink — `pairing.deviceId` was set to the **daemon's** device id parsed from `amux://join?...&device=...&token=...`. The same field doubled as the iOS-side reply-routing identifier in teamclaw RPC because the two values happened to be the same back when one daemon and one iOS app were directly paired 1:1.

Phase 4 broke that. With invite tokens gone, `pairing.deviceId` defaults to empty on first launch. Two symptoms follow:

1. **Routing**: `runtimeStartRpc` sets `RpcRequest.sender_device_id = pairing.deviceId` (`TeamclawService.swift:896`). With it empty, the daemon publishes the RpcResponse to `amux/{team}/device//rpc/res` (note the empty path segment). iOS subscribes to its own `device/{pairing.deviceId}/rpc/res` — the topic strings happen to match, but every other surface that depends on a non-empty install identity (LWT-style tracing, future per-iOS-client subscriptions, broker logs, troubleshooting) is broken.

2. **UX**: `NewSessionSheet`'s workspace + agent rows are gated on `primaryAgentID != nil` (`shouldShowWorkspaceRow`, `NewSessionSheet.swift:58`). `primaryAgentID` is only ever set inside the Collaborators-picker callback (`NewSessionSheet.swift:162-185`). With nothing driving the picker, the rows never render and the user sees a half-empty sheet — the prompt still goes through (`effectiveDeviceID`'s `inferredDeviceIDs` fallback picks the only accessible agent), but the sheet looks broken and the user has no control over the workspace or agent type.

`NewSessionSheet` already has a third identity — `requesterDeviceID` (`NewSessionSheet.swift:59-61`) computed from `UIDevice.identifierForVendor` — and uses it to *filter out* the case where `pairing.deviceId == requesterDeviceID`. The clean fix is to **promote `requesterDeviceID` into `PairingManager`** as a first-class field, populated automatically and never overloaded.

---

## File Map

| Status | Path | Change |
|--------|------|--------|
| Modify | `ios/Packages/AMUXCore/Sources/AMUXCore/CredentialStore.swift` | Add `requesterDeviceID` to `PairingCredentials` |
| Modify | `ios/Packages/AMUXCore/Sources/AMUXCore/PairingManager.swift` | Auto-populate `requesterDeviceID` on first launch; expose as `pairing.requesterDeviceID` |
| Modify | `ios/Packages/AMUXCore/Sources/AMUXCore/TeamclawService.swift` | Take `requesterDeviceID` in `start()`; use it for `senderDeviceID` and `ownResTopic` instead of `deviceId` |
| Modify | `ios/AMUXApp/ContentView.swift` | Pass `pairing.requesterDeviceID` into `teamclawService.start(...)` |
| Modify | `ios/Packages/AMUXUI/Sources/AMUXUI/SessionList/NewSessionSheet.swift` | Replace local `requesterDeviceID` computed prop with the one from `PairingManager`; add onChange that auto-picks `primaryAgentID` from `connectedAgentsStore.agents` when there is exactly one accessible agent |
| Modify | `ios/Packages/AMUXCore/Tests/AMUXCoreTests/PairingManagerTests.swift` | Cover the auto-populate-on-first-launch path |

`pairing.deviceId` keeps its original semantic — the user-configurable Daemon ID surfaced in Settings → MQTT Server. Leaving it empty after Phase 4 is fine; `effectiveDeviceID`'s existing inferred-from-`connectedAgentsStore` fallback handles that.

---

## Task 1: Split iOS-install identity from Daemon ID

**Files:**
- Modify: `ios/Packages/AMUXCore/Sources/AMUXCore/CredentialStore.swift`
- Modify: `ios/Packages/AMUXCore/Sources/AMUXCore/PairingManager.swift`
- Modify: `ios/Packages/AMUXCore/Tests/AMUXCoreTests/PairingManagerTests.swift`

- [ ] **Step 1.1: Add `requesterDeviceID` to `PairingCredentials`**

Append a `requesterDeviceID: String` field to `PairingCredentials` and to its `UserDefaults` keys (`amux_requester_device_id`). Decode missing values from older stores as empty so existing installs don't fail to load.

- [ ] **Step 1.2: Auto-populate on first launch**

In `PairingManager.applyDefaults()` (and in a new `else if requesterDeviceID.isEmpty` branch on the `init`'s post-`loadFromStore` check), set `requesterDeviceID = UUID().uuidString.lowercased()` when empty. Persist via `store.save(currentCredentials())`. Once set, never overwrite.

Expose `requesterDeviceID` as a public read-only property mirroring `brokerHost` / `deviceId`.

- [ ] **Step 1.3: Test coverage**

In `PairingManagerTests.swift`, add cases:
- Fresh install (empty `InMemoryStore`): after init, `requesterDeviceID` is a non-empty UUID and the same value persists across a second `PairingManager` constructed with the same store.
- Existing install with empty `requesterDeviceID` and populated `brokerHost`: backfill triggers and the value persists.
- Existing install with non-empty `requesterDeviceID`: value preserved (no rotation on re-launch).

## Task 2: Use `requesterDeviceID` for RPC reply routing

**Files:**
- Modify: `ios/Packages/AMUXCore/Sources/AMUXCore/TeamclawService.swift`
- Modify: `ios/AMUXApp/ContentView.swift`

- [ ] **Step 2.1: Thread `requesterDeviceID` into `TeamclawService`**

Add a `requesterDeviceID: String` parameter to `TeamclawService.start(...)` and store it as a property. Passing the existing `deviceId` continues to mean "Daemon ID for fallback target" and is unchanged.

- [ ] **Step 2.2: Use it as `sender_device_id`**

In `TeamclawService.runtimeStartRpc(...)` (`TeamclawService.swift:896`):

```swift
rpcReq.senderDeviceID = requesterDeviceID
```

In the same method, replace the rpc/res subscribe topics to use `requesterDeviceID`:

```swift
let ownResTopic = MQTTTopics.deviceRpcResponse(teamID: teamId, deviceID: requesterDeviceID)
```

Apply the same change to **every** other `Teamclaw_RpcRequest` constructed in `TeamclawService.swift` — there are nine call sites (`grep -n "rpcReq.senderDeviceID = deviceId"`). All of them want the iOS install id, not the Daemon ID.

- [ ] **Step 2.3: Subscribe at `start()`**

The `start()` method's existing `try? await mqtt.subscribe(MQTTTopics.deviceRpcResponse(teamID: teamId, deviceID: deviceId))` (`TeamclawService.swift:82`) becomes `deviceID: requesterDeviceID`.

- [ ] **Step 2.4: Wire in `ContentView`**

In `ContentView.connectMQTT()` (`ContentView.swift:145`), pass `pairing.requesterDeviceID` to `teamclawService.start(...)`. Existing `deviceId: pairing.deviceId` parameter remains in case a future flow uses it as a fallback Daemon ID hint.

## Task 3: Auto-pick `primaryAgentID` in `NewSessionSheet`

**Files:**
- Modify: `ios/Packages/AMUXUI/Sources/AMUXUI/SessionList/NewSessionSheet.swift`

- [ ] **Step 3.1: Replace the local computed prop**

Remove the local `requesterDeviceID` computed prop (`NewSessionSheet.swift:59-61`). Add a stored let `requesterDeviceID: String` parameter on the initializer; pass `pairing.requesterDeviceID` from `SessionsTab.swift` (and from any other call site of `NewSessionSheet.init`). Replace the `effectiveDeviceID` callers' references unchanged — they read the same value now from a different field.

- [ ] **Step 3.2: Auto-select primary on agent-set change**

Add an onChange near `NewSessionSheet`'s existing `.task` (`NewSessionSheet.swift:222`):

```swift
.onChange(of: connectedAgentsStore?.agents.map(\.id) ?? []) { _, agentIDs in
    // Auto-select the only accessible agent so the workspace + agent
    // rows render without forcing the user through the Collaborators
    // picker. Phase 3 set primaryAgentID implicitly via pairing.deviceId;
    // post-Phase 4 the discovery happens through connectedAgentsStore.
    guard primaryAgentID == nil, agentIDs.count == 1 else { return }
    primaryAgentID = agentIDs.first
}
```

- [ ] **Step 3.3: Reload `connectedAgentsStore` on appear if empty**

If the sheet opens before `RootTabView.configureStores()` has populated the store, `connectedAgentsStore?.agents` will be empty when the onChange fires once. Add to the existing `.task` at `NewSessionSheet.swift:222`:

```swift
if let store = connectedAgentsStore, store.agents.isEmpty {
    await store.reload()
}
```

This complements the existing reload inside the Collaborators picker's `.task`.

## Task 4: Verification

- [ ] **Step 4.1: Unit + library build**

```bash
cd ios/Packages/AMUXCore && swift build && swift test
```

`PairingManagerTests` should cover the new field. No other AMUXCore tests should regress.

- [ ] **Step 4.2: Run the streaming UI test**

```bash
cd ios && xcodebuild test \
  -project AMUX.xcodeproj -scheme AMUXUITests \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:AMUXUITests/AMUXSessionStreamingUITests/testNewSessionStreamsAssistantOutput \
  AMUX_TEST_EMAIL=<test-account-email> AMUX_TEST_PASSWORD=<test-account-password>
```

Pre-conditions for the test environment (replicate from the Phase 4 cutover session if needed):
- Test account belongs to the same team as a running daemon and has `agent_member_access` on it.
- Daemon is running locally and connected to the broker.
- The test account has exactly one agent in `connectedAgentsStore` (so auto-pick has no ambiguity).

Expected: the test passes within ~30s. The assistant output `'hi from amux ui test'` lands in the detail view as a static text.

- [ ] **Step 4.3: Daemon-side observation**

Watch the daemon log during the test:

```
INFO publishing RpcResponse request_id=<id> res_topic=amux/<team>/device/<requesterDeviceID>/rpc/res success=true
```

The `<requesterDeviceID>` slot must now be a non-empty UUID — never empty. If it is empty, Step 1.1 or Step 2.2 missed a call site.

- [ ] **Step 4.4: Settings UI sanity check**

Open Settings → MQTT Server. The "Daemon ID" field should still show the user-configurable `pairing.deviceId` (typically empty after Phase 4 unless the user typed one) — **not** the iOS install UUID. The install UUID is internal and never user-facing.

---

## Out of Scope

- Daemon-side defensive rejection of RPC requests with empty `sender_device_id` — useful but separate; iOS will always populate after this plan.
- Settings UI to display or rotate `requesterDeviceID` — it is intentionally invisible to the user.
- Broader refactor of `pairing.deviceId` semantics (it remains "user-configurable Daemon ID for legacy / manual pairing"); macOS shell still uses the `pair(from:)` deeplink path which writes to it.
- Per-account or per-install rotation of `requesterDeviceID` (e.g., on sign-out) — not needed for correctness; the broker treats it as an opaque routing token.
