# MQTT Topic Redesign — Phase 2b Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** iOS switches peers and workspaces from retained-topic subscriptions to `FetchPeers` / `FetchWorkspaces` RPC calls with `device/{id}/notify`-driven refresh. Resolves a latent Phase 1b bug where two incompatible proto messages (`Notify` and `NotifyEnvelope`) share the `device/{id}/notify` topic by migrating the legacy `NotifyPublisher::publish_membership_refresh` to the new `Notify` shape and teaching both daemon and iOS to decode both formats for a bounded compat window. After this plan ships, daemon can retire retained `device/{id}/peers` and `device/{id}/workspaces` publishes in Phase 3. Collab-op MUTATIONS (AnnouncePeer / DisconnectPeer / AddWorkspace / RemoveWorkspace / RemoveMember via `/collab`) stay on legacy — Phase 2c handles them.

**Architecture:** Phase 1b added `Publisher::publish_notify` emitting `Teamclaw_Notify { event_type, refresh_hint, sent_at }` on change. Phase 0 `NotifyEnvelope` (wire-incompatible fields) is still emitted by `NotifyPublisher::publish_membership_refresh`. Phase 2b Task 2 migrates `NotifyPublisher` to use `Notify` with `event_type = "membership.refresh"` and `refresh_hint = session_id` — the three session_manager.rs call sites get the semantic substitution, and `NotifyEnvelope` becomes compat-only wire surface. Both daemon decoder (`server.rs:721`) and iOS decoder (`TeamclawService.swift:131`) accept either format for one release window; Phase 5 deletes `NotifyEnvelope`. Tasks 3–6 do the iOS read-path switch: `TeamclawService` gains `fetchPeers()` / `fetchWorkspaces()` RPC helpers, stops subscribing to the retained topics, calls the RPCs on connect + on `Notify { event_type: "peers.changed" | "workspaces.changed" }` hints.

**Tech Stack:** Swift (SwiftProtobuf, mqtt-nio/CocoaMQTT), Rust (prost, rumqttc). No new dependencies.

**Reference:** `docs/superpowers/specs/2026-04-24-mqtt-topic-redesign-design.md` — "Peers recovery model", "device/notify vs user/notify scoping", "Migration Plan → Phase 2".

**Out of scope for Phase 2b:**
- **Collab MUTATIONS (AnnouncePeer / DisconnectPeer / AddWorkspace / RemoveWorkspace / RemoveMember).** iOS still publishes these to `device/{id}/collab`. Phase 2c migrates each mutation call site (`WorkspaceManagementView.swift`, `NewSessionSheet.swift`, `MemberListContent.swift`) to use the RPC handlers landed in Phase 1b (`AnnouncePeerRequest`, etc.).
- **`RuntimeStart` RPC adoption.** Phase 2c.
- **SwiftData `Agent` → `Runtime` rename + legacy `MQTTTopics` method deletion.** Phase 2d.
- **`user/{actor}/notify` subscription.** Gated on Phase 1d (Supabase `user_inbox` table + EMQX JWT auth).
- **Deleting `Teamclaw_NotifyEnvelope` proto message.** Daemon + iOS still decode both formats after this plan. `NotifyEnvelope` is compat-only; Phase 5 deletes it.

---

## File Structure

**Rust files edited:**
- `daemon/src/teamclaw/notify.rs` — `NotifyPublisher::publish_membership_refresh` migrates to publish `Notify` instead of `NotifyEnvelope`. Method name and signature stay for caller stability.
- `daemon/src/daemon/server.rs` — `TeamclawNotify` decoder tries `Notify` first, falls back to `NotifyEnvelope`. Both trigger the same membership-refresh response when `event_type == "membership.refresh"`.

**Swift files edited:**
- `ios/Packages/AMUXCore/Sources/AMUXCore/TeamclawService.swift` — add `fetchPeers()` and `fetchWorkspaces()` RPC helper methods. `deviceNotify` decoder tries `Teamclaw_Notify` first, falls back to `Teamclaw_NotifyEnvelope`. Remove `devicePeers` subscription; call `fetchPeers()` on start + on `Notify.event_type == "peers.changed"`. Add `members.changed` handler (re-fetch members — the existing membership refresh flow already covers this via `membership.refresh`; treat `members.changed` as equivalent).
- `ios/Packages/AMUXCore/Sources/AMUXCore/ViewModels/SessionListViewModel.swift` — remove `deviceWorkspaces` subscription; invoke `teamclawService.fetchWorkspaces()` on start + on notify-driven refresh signal.

**Behavior at end of Phase 2b:**
- Daemon publishes all `device/{id}/notify` events using the `Notify` shape. Legacy `NotifyEnvelope` is no longer emitted, but decoded as compat.
- iOS decodes `Notify` uniformly on `deviceNotify`; legacy `NotifyEnvelope` payloads are also handled in case a pre-Phase-2b daemon version is paired.
- iOS calls `FetchPeers` RPC on MQTT connect, on `Notify { event_type: "peers.changed" }`, and on `Notify { event_type: "members.changed" }`. No subscription to retained `devicePeers` topic.
- iOS calls `FetchWorkspaces` RPC on MQTT connect and on `Notify { event_type: "workspaces.changed" }`. No subscription to retained `deviceWorkspaces` topic.
- `devicePeers` / `deviceWorkspaces` retained topics are still published by the daemon (for legacy iOS clients on Phase 2a or older). Phase 3 removes them.
- Tests updated where they reference the legacy notify decode.
- iOS mutations (AnnouncePeer / AddWorkspace / RemoveMember / etc.) still flow through `/collab`. Phase 2c migrates them.

**Ordering constraint:** Task 2 (daemon NotifyPublisher migration) must ship together with Task 4 (iOS decoder accepting both). If daemon upgrades without iOS, old iOS sees Notify payloads on deviceNotify and fails to decode them as NotifyEnvelope — membership-refresh events get dropped. The migration must be transactional in release terms: both daemon + iOS updates land together.

---

## Task 1: Verify green baseline

**Files:** none (verification only)

- [ ] **Step 1: Confirm daemon 104+ tests pass, iOS build green at Phase 2a final**

```bash
cd /Volumes/openbeta/workspace/amux/daemon && set -a && source .env && set +a && cargo test --no-fail-fast 2>&1 | grep "cargo test:" | tail -1
cd /Volumes/openbeta/workspace/amux/ios && xcodebuild -project AMUX.xcodeproj -scheme AMUX -destination 'generic/platform=iOS' -configuration Debug build CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "BUILD SUCCEEDED|BUILD FAILED" | head -2
```
Expected: `cargo test: 104 passed`, `** BUILD SUCCEEDED **`.

- [ ] **Step 2: Confirm HEAD**

```bash
cd /Volumes/openbeta/workspace/amux && git log --oneline -1
```
Expected: `584556e0 feat(ios): AgentDetailViewModel uses runtime/{id}/events and runtime/{id}/commands` or later.

No commit in this task.

---

## Task 2: Daemon — migrate `NotifyPublisher` to use `Notify`; decoder accepts both formats

**Files:**
- Modify: `daemon/src/teamclaw/notify.rs`
- Modify: `daemon/src/daemon/server.rs`

`NotifyPublisher::publish_membership_refresh(target_device_id, session_id, reason)` currently publishes `Teamclaw_NotifyEnvelope`. Switch to `Teamclaw_Notify { event_type: "membership.refresh", refresh_hint: session_id, sent_at }`. The `target_device_id` parameter still determines the topic path (`device/{target_device_id}/notify`). The `reason` parameter becomes unused at the wire level but stays in the method signature — inside the method body, write `let _ = reason;` with a comment noting it's preserved for logging/future telemetry. Three call sites in `session_manager.rs` pass reasons like `"participant_joined"` / `"participant_added"` / `"participant_removed"` — those call sites don't change.

Daemon's decoder in `server.rs::handle_incoming` (around line 721) currently only decodes `NotifyEnvelope`. Extend it to try `Notify` first, fall back to `NotifyEnvelope`.

- [ ] **Step 1: Update `NotifyPublisher::publish_membership_refresh` in `daemon/src/teamclaw/notify.rs`**

Replace the existing implementation of the method body. Current:
```rust
    pub async fn publish_membership_refresh(
        &self,
        target_device_id: &str,
        session_id: &str,
        reason: &str,
    ) -> crate::error::Result<()> {
        let payload = NotifyEnvelope {
            event_id: Uuid::new_v4().to_string(),
            event_type: "membership.refresh".to_string(),
            target_device_id: target_device_id.to_string(),
            session_id: session_id.to_string(),
            sent_at: Utc::now().timestamp(),
            reason: reason.to_string(),
        }
        .encode_to_vec();

        let topic = Topics::new(&self.team_id, target_device_id).device_notify();
        self.client
            .publish(topic, QoS::AtLeastOnce, false, payload)
            .await?;
        Ok(())
    }
```

Replace with:

```rust
    pub async fn publish_membership_refresh(
        &self,
        target_device_id: &str,
        session_id: &str,
        reason: &str,
    ) -> crate::error::Result<()> {
        // Preserved in signature for logging / future telemetry; Phase 2b wire
        // shape drops the field because Notify is payload-minimal.
        let _ = reason;

        let payload = crate::proto::teamclaw::Notify {
            event_type: "membership.refresh".to_string(),
            refresh_hint: session_id.to_string(),
            sent_at: Utc::now().timestamp(),
        }
        .encode_to_vec();

        let topic = Topics::new(&self.team_id, target_device_id).device_notify();
        self.client
            .publish(topic, QoS::AtLeastOnce, false, payload)
            .await?;
        Ok(())
    }
```

Also update the `use` statement at the top: remove `use crate::proto::teamclaw::NotifyEnvelope;` (now unused in this file — keep only `Uuid` removed too if unused; Swift compiler will flag).

Actually remove BOTH unused imports that result: `NotifyEnvelope` and `Uuid::new_v4()` (since we no longer mint an event_id — the new `Notify` shape doesn't have one). After the change, the file should only import what it still uses: `prost::Message`, `rumqttc::{AsyncClient, QoS}`, `chrono::Utc`, `crate::mqtt::Topics`, and `crate::proto::teamclaw` (for `Notify`).

- [ ] **Step 2: Update daemon decoder in `server.rs` to accept both formats**

Find the `TeamclawNotify` arm in `handle_incoming` (around line 721):

```rust
            subscriber::IncomingMessage::TeamclawNotify { device_id: _, payload } => {
                if let Ok(envelope) = crate::proto::teamclaw::NotifyEnvelope::decode(payload.as_slice()) {
                    if envelope.event_type == "membership.refresh" && !envelope.session_id.is_empty() {
                        if let Some(tc) = &mut self.teamclaw {
                            if let Err(err) = tc.refresh_membership_subscriptions().await {
                                warn!(?err, session_id = %envelope.session_id, "failed to refresh membership subscriptions after notify");
                            }
                        }
                    }
                }
            }
```

Replace with:

```rust
            subscriber::IncomingMessage::TeamclawNotify { device_id: _, payload } => {
                // Phase 2b: device/{id}/notify carries two wire shapes during the
                // compat window — new Teamclaw_Notify (event_type + refresh_hint)
                // and legacy NotifyEnvelope (pre-Phase-2b daemons still emit it).
                // Field numbers are wire-incompatible: try Notify first (smaller
                // schema, safer false-positive on short payloads), fall back to
                // NotifyEnvelope for old-format messages.
                let (event_type, refresh_hint) = if let Ok(n) =
                    crate::proto::teamclaw::Notify::decode(payload.as_slice())
                {
                    (n.event_type, n.refresh_hint)
                } else if let Ok(env) =
                    crate::proto::teamclaw::NotifyEnvelope::decode(payload.as_slice())
                {
                    (env.event_type, env.session_id)
                } else {
                    warn!("failed to decode device/notify payload as Notify or NotifyEnvelope");
                    continue;
                };

                if event_type == "membership.refresh" && !refresh_hint.is_empty() {
                    if let Some(tc) = &mut self.teamclaw {
                        if let Err(err) = tc.refresh_membership_subscriptions().await {
                            warn!(?err, session_id = %refresh_hint, "failed to refresh membership subscriptions after notify");
                        }
                    }
                }
            }
```

Note: if the surrounding code uses `return;` instead of `continue` (depends on whether we're in a loop or a match arm body), adapt. Looking at the Phase 0/1 code: this is a match arm inside `handle_incoming` which is itself inside `match msg { ... }`. Neither `continue` nor `return;` applies cleanly inside a match arm body. The fix: use `return;` since `handle_incoming` is a method that returns `()`; the match ends after any arm. OR wrap the decode-fallback logic so the default case (decode failed) just does nothing:

```rust
            subscriber::IncomingMessage::TeamclawNotify { device_id: _, payload } => {
                let parsed: Option<(String, String)> = if let Ok(n) =
                    crate::proto::teamclaw::Notify::decode(payload.as_slice())
                {
                    Some((n.event_type, n.refresh_hint))
                } else if let Ok(env) =
                    crate::proto::teamclaw::NotifyEnvelope::decode(payload.as_slice())
                {
                    Some((env.event_type, env.session_id))
                } else {
                    warn!("failed to decode device/notify payload as Notify or NotifyEnvelope");
                    None
                };

                if let Some((event_type, refresh_hint)) = parsed {
                    if event_type == "membership.refresh" && !refresh_hint.is_empty() {
                        if let Some(tc) = &mut self.teamclaw {
                            if let Err(err) = tc.refresh_membership_subscriptions().await {
                                warn!(?err, session_id = %refresh_hint, "failed to refresh membership subscriptions after notify");
                            }
                        }
                    }
                }
            }
```

Use this second form.

- [ ] **Step 3: Compile + test**

```bash
cd /Volumes/openbeta/workspace/amux/daemon && set -a && source .env && set +a && cargo build 2>&1 | tail -3 && cargo test --no-fail-fast 2>&1 | grep "cargo test:" | tail -1
```
Expected: 104+ tests pass. If any tests decode `NotifyEnvelope` from daemon-produced payloads, they now receive `Notify` payloads — those tests need to be updated to expect the new shape, OR they should decode both formats. Search daemon tests:

```bash
grep -rn "NotifyEnvelope\|publish_membership_refresh" daemon/src daemon/tests 2>/dev/null
```

If any test assertions depend on `NotifyEnvelope` fields (especially `target_device_id` or `event_id`), update them to decode `Notify` instead and assert on `event_type` + `refresh_hint`.

- [ ] **Step 4: Commit**

```bash
cd /Volumes/openbeta/workspace/amux && git add daemon/src/teamclaw/notify.rs daemon/src/daemon/server.rs && git commit -m "$(cat <<'EOF'
refactor(notify): migrate NotifyPublisher to Notify; decoder accepts both

NotifyPublisher::publish_membership_refresh now emits Teamclaw_Notify
{event_type: "membership.refresh", refresh_hint: session_id} instead of
the legacy NotifyEnvelope. Field numbers between Notify and
NotifyEnvelope are wire-incompatible, which was a latent Phase 1b bug —
both types were being published on the same device/{id}/notify topic
with different wire shapes. This unifies all daemon notify publishes
on Notify.

Daemon decoder tries Notify first, falls back to NotifyEnvelope for
the compat window (pre-Phase-2b daemons still emit NotifyEnvelope).
NotifyEnvelope stays in the proto until Phase 5 deletes it.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

If any tests also needed updates, include those files in the same commit (keep the change bundled).

---

## Task 3: iOS — add `fetchPeers()` / `fetchWorkspaces()` RPC helpers

**Files:**
- Modify: `ios/Packages/AMUXCore/Sources/AMUXCore/TeamclawService.swift`

Mirror the existing `archiveTask`, `updateTaskStatus`, etc. RPC helper pattern (the file already has many examples). Each helper: builds `Teamclaw_RpcRequest`, publishes to `deviceRpcRequest`, awaits correlated response on `deviceRpcResponse`, returns the result. `Teamclaw_FetchPeersResult.peers` and `Teamclaw_FetchWorkspacesResult.workspaces` are Phase 0 Task 11 proto fields.

- [ ] **Step 1: Add `fetchPeers()` method**

Append to the `public final class TeamclawService { ... }` body (near the other RPC helpers, around line 440-700):

```swift
    /// Fetches the daemon's current in-memory peer set via FetchPeers RPC.
    /// Phase 2b replacement for the retained devicePeers topic subscription.
    /// Returns empty array on timeout or decode error — the retained topic
    /// semantics degraded the same way, and callers are idempotent.
    public func fetchPeers() async -> [Amux_PeerInfo] {
        guard let mqtt else { return [] }

        var fetch = Teamclaw_FetchPeersRequest()  // empty request

        var rpcReq = Teamclaw_RpcRequest()
        rpcReq.requestID = String(UUID().uuidString.prefix(8)).lowercased()
        rpcReq.senderDeviceID = deviceId
        rpcReq.method = .fetchPeers(fetch)

        let requestId = rpcReq.requestID
        let topic = MQTTTopics.deviceRpcRequest(teamID: teamId, deviceID: deviceId)
        let stream = mqtt.messages()

        guard let data = try? rpcReq.serializedData() else { return [] }
        try? await mqtt.publish(topic: topic, payload: data, retain: false)

        let deadline = Date().addingTimeInterval(10)
        for await msg in stream {
            if Date() > deadline { break }
            if msg.topic == MQTTTopics.deviceRpcResponse(teamID: teamId, deviceID: deviceId),
               let response = try? Teamclaw_RpcResponse(serializedBytes: msg.payload),
               response.requestID == requestId {
                if case let .fetchPeersResult(result)? = response.result {
                    return result.peers
                }
                return []
            }
        }
        return []
    }
```

- [ ] **Step 2: Add `fetchWorkspaces()` method**

Right after `fetchPeers()`:

```swift
    /// Fetches the daemon's workspace set via FetchWorkspaces RPC.
    /// Phase 2b replacement for the retained deviceWorkspaces topic subscription.
    public func fetchWorkspaces() async -> [Amux_WorkspaceInfo] {
        guard let mqtt else { return [] }

        var fetch = Teamclaw_FetchWorkspacesRequest()  // empty request

        var rpcReq = Teamclaw_RpcRequest()
        rpcReq.requestID = String(UUID().uuidString.prefix(8)).lowercased()
        rpcReq.senderDeviceID = deviceId
        rpcReq.method = .fetchWorkspaces(fetch)

        let requestId = rpcReq.requestID
        let topic = MQTTTopics.deviceRpcRequest(teamID: teamId, deviceID: deviceId)
        let stream = mqtt.messages()

        guard let data = try? rpcReq.serializedData() else { return [] }
        try? await mqtt.publish(topic: topic, payload: data, retain: false)

        let deadline = Date().addingTimeInterval(10)
        for await msg in stream {
            if Date() > deadline { break }
            if msg.topic == MQTTTopics.deviceRpcResponse(teamID: teamId, deviceID: deviceId),
               let response = try? Teamclaw_RpcResponse(serializedBytes: msg.payload),
               response.requestID == requestId {
                if case let .fetchWorkspacesResult(result)? = response.result {
                    return result.workspaces
                }
                return []
            }
        }
        return []
    }
```

- [ ] **Step 3: Verify iOS compiles**

```bash
cd /Volumes/openbeta/workspace/amux/ios && xcodebuild -project AMUX.xcodeproj -scheme AMUX -destination 'generic/platform=iOS' -configuration Debug build CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "BUILD SUCCEEDED|BUILD FAILED|error:" | head -5
```

Expected: `** BUILD SUCCEEDED **`. If the `.fetchPeersResult(...)` / `.fetchWorkspacesResult(...)` case labels don't match what swift-protobuf generated from the Phase 0 proto, check `ios/Packages/AMUXCore/Sources/AMUXCore/Proto/teamclaw.pb.swift` for the exact oneof case names and adapt.

- [ ] **Step 4: Commit**

```bash
cd /Volumes/openbeta/workspace/amux && git add ios/Packages/AMUXCore/Sources/AMUXCore/TeamclawService.swift && git commit -m "$(cat <<'EOF'
feat(ios): add fetchPeers / fetchWorkspaces RPC helpers to TeamclawService

Mirrors the existing RPC helper pattern (archiveTask, updateTaskStatus
etc.). Each method builds a Teamclaw_RpcRequest, publishes to
deviceRpcRequest, awaits a correlated response on deviceRpcResponse
with a 10-second timeout, returns the repeated field from the Result
or an empty array on timeout / decode failure.

Not yet wired into any call site — Tasks 5 and 6 switch the existing
retained-topic consumers over.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: iOS — decode both `Notify` and `NotifyEnvelope` on deviceNotify; route `peers.changed` / `workspaces.changed`

**Files:**
- Modify: `ios/Packages/AMUXCore/Sources/AMUXCore/TeamclawService.swift`

Current code (around line 129) decodes only `Teamclaw_NotifyEnvelope` and handles `event_type == "membership.refresh"` using `envelope.sessionID`. Phase 2b: try `Teamclaw_Notify` first, fall back to `Teamclaw_NotifyEnvelope`. Add branches for `peers.changed` and `workspaces.changed` that kick off a refresh. `members.changed` can be treated the same as `membership.refresh` (both end up re-fetching session/member state).

- [ ] **Step 1: Read the existing deviceNotify handler block**

Look at `TeamclawService.swift` around line 129 (lines 128-139). Confirm shape.

- [ ] **Step 2: Rewrite the deviceNotify decoder**

Replace:

```swift
        if topic == MQTTTopics.deviceNotify(teamID: teamId, deviceID: deviceId) {
            guard let envelope = try? Teamclaw_NotifyEnvelope(serializedBytes: incoming.payload) else {
                print("[TeamclawService] failed to decode NotifyEnvelope from topic: \(topic)")
                return
            }
            if envelope.eventType == "membership.refresh", !envelope.sessionID.isEmpty {
                await refreshSessionState(for: envelope.sessionID, modelContext: modelContext)
            }
            return
        }
```

with:

```swift
        if topic == MQTTTopics.deviceNotify(teamID: teamId, deviceID: deviceId) {
            // Phase 2b: device/{id}/notify carries two wire shapes during the
            // compat window — new Teamclaw_Notify (event_type + refresh_hint,
            // field numbers 1-3) and legacy NotifyEnvelope (pre-Phase-2b
            // daemons still emit it on membership.refresh). Try Notify first;
            // fall back to NotifyEnvelope for old-format messages.
            let parsed: (eventType: String, refreshHint: String)?
            if let notify = try? Teamclaw_Notify(serializedBytes: incoming.payload) {
                parsed = (notify.eventType, notify.refreshHint)
            } else if let envelope = try? Teamclaw_NotifyEnvelope(serializedBytes: incoming.payload) {
                parsed = (envelope.eventType, envelope.sessionID)
            } else {
                print("[TeamclawService] failed to decode device/notify payload as Notify or NotifyEnvelope")
                return
            }

            guard let (eventType, refreshHint) = parsed else { return }

            switch eventType {
            case "membership.refresh", "members.changed":
                if !refreshHint.isEmpty {
                    await refreshSessionState(for: refreshHint, modelContext: modelContext)
                }
            case "peers.changed":
                // Full refresh of the peer cache via RPC. Tasks 5 does the
                // integration (TeamclawService needs a SwiftData peer sync
                // target or a callback; implementer: follow the existing
                // `refreshSessionState` pattern).
                _ = await fetchPeers()
                // [integration hook — Task 5 wires the returned array into
                // SwiftData/Observable state. For Task 4 only, calling and
                // discarding is acceptable as a placeholder.]
            case "workspaces.changed":
                _ = await fetchWorkspaces()
                // [same — Task 6 wires the returned array in.]
            default:
                break
            }
            return
        }
```

Note: the `_ = await fetchPeers()` and `_ = await fetchWorkspaces()` lines are placeholders for Task 4 — they fire the RPC but discard the result. Task 5 and Task 6 wire the returned arrays into actual state updates. Having the RPC fire from the notify handler now means the daemon side is exercised end-to-end earlier.

- [ ] **Step 3: Verify iOS compiles**

```bash
cd /Volumes/openbeta/workspace/amux/ios && xcodebuild -project AMUX.xcodeproj -scheme AMUX -destination 'generic/platform=iOS' -configuration Debug build CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "BUILD SUCCEEDED|BUILD FAILED|error:" | head -5
```

- [ ] **Step 4: Update existing tests that mock deviceNotify payloads**

Find:

```bash
grep -rn "Teamclaw_NotifyEnvelope\|deviceNotify" ios/Packages/AMUXCore/Tests --include='*.swift'
```

If any test constructs a `Teamclaw_NotifyEnvelope { event_type: "membership.refresh", session_id: ... }` and publishes it to simulate notify traffic — those tests still work (decoder still accepts NotifyEnvelope). Add additional tests that use `Teamclaw_Notify { event_type: "membership.refresh", refresh_hint: ... }` to cover the new path. Optional for MVP; baseline tests still pass.

- [ ] **Step 5: Commit**

```bash
cd /Volumes/openbeta/workspace/amux && git add ios/Packages/AMUXCore/Sources/AMUXCore/TeamclawService.swift && git commit -m "$(cat <<'EOF'
feat(ios): decode Notify + NotifyEnvelope on deviceNotify; route new event types

Switches TeamclawService's deviceNotify handler from NotifyEnvelope-only
to a two-format decode (Notify first, NotifyEnvelope fallback). Accepts
new event types peers.changed and workspaces.changed by firing
fetchPeers / fetchWorkspaces RPCs (return values discarded for now —
Tasks 5 and 6 wire them into state). members.changed is handled the
same way as membership.refresh. Phase 5 will delete the NotifyEnvelope
fallback.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: iOS — switch peers from retained subscription to RPC + notify

**Files:**
- Modify: `ios/Packages/AMUXCore/Sources/AMUXCore/TeamclawService.swift`

Currently TeamclawService subscribes to `devicePeers` (line 84) and handles retained `PeerList` payloads (line 115). Switch to:
1. Drop the `devicePeers` subscribe
2. Drop the `devicePeers` payload handler
3. On MQTT connect, call `fetchPeers()` and wire the result into whatever state the retained-payload handler updates today
4. In the notify handler from Task 4, replace `_ = await fetchPeers()` with a call that actually wires the result into state

- [ ] **Step 1: Identify what the current retained-payload handler does**

Look at `TeamclawService.swift:115` and the block below it. Find the SwiftData sync function, `@Observable` property update, or callback that consumes the decoded `Amux_PeerList`. Call this the "peer sync target" — Task 5 Step 3 reroutes `fetchPeers()` results through it.

- [ ] **Step 2: Extract peer-sync into a reusable helper**

If the retained-payload handler currently inlines the sync logic, extract it into a private method:

```swift
    private func syncPeers(_ peers: [Amux_PeerInfo], modelContext: ModelContext) {
        // Move the body of the retained-payload handler here — whatever
        // it currently does to update SwiftData Peer models / observable
        // properties / etc.
    }
```

The helper takes a `[Amux_PeerInfo]` (what `FetchPeersResult.peers` returns and what `Amux_PeerList.peers` carries — same type). The existing retained handler can call `syncPeers(peerList.peers, modelContext: ...)` instead of inlining.

**If the existing handler is already small and calls a single method, skip this step and use whatever method exists.**

- [ ] **Step 3: Remove `devicePeers` subscribe + handler**

Find the subscribe call at `TeamclawService.swift:84`:

```swift
            try? await mqtt.subscribe(MQTTTopics.devicePeers(teamID: teamId, deviceID: deviceId))
```

Delete this line.

Find the handler around line 115:

```swift
        if topic == MQTTTopics.devicePeers(teamID: teamId, deviceID: deviceId) {
            // ... existing decode + sync logic ...
            return
        }
```

Delete the entire `if` block.

- [ ] **Step 4: Call `fetchPeers()` on connect + wire the result**

Find where TeamclawService's MQTT subscription loop runs (probably right after `subscribe_all` or similar). After successfully subscribing, call:

```swift
            let peers = await fetchPeers()
            syncPeers(peers, modelContext: modelContext)
```

(Adapt to whatever pattern the extracted helper requires — passing modelContext / using @MainActor / etc.)

- [ ] **Step 5: Wire the notify handler from Task 4**

In the Task 4 notify handler, replace `_ = await fetchPeers()` with:

```swift
            case "peers.changed":
                let peers = await fetchPeers()
                syncPeers(peers, modelContext: modelContext)
```

Do the same for `members.changed` if members traffic flows through `syncPeers` (checking with the implementer — if members are a separate sync, fire whatever the equivalent members-refresh helper is).

- [ ] **Step 6: Verify iOS compiles + tests**

```bash
cd /Volumes/openbeta/workspace/amux/ios && xcodebuild -project AMUX.xcodeproj -scheme AMUX -destination 'generic/platform=iOS' -configuration Debug build CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "BUILD SUCCEEDED|BUILD FAILED|error:" | head -5
```

Expected: `** BUILD SUCCEEDED **`.

Also update `Tests/AMUXCoreTests/TeamclawServiceSubscriptionTests.swift` if it asserts the `devicePeers` subscribe:

```bash
grep -n "devicePeers" ios/Packages/AMUXCore/Tests/AMUXCoreTests/TeamclawServiceSubscriptionTests.swift
```

If the test expects TeamclawService to subscribe to `devicePeers`, remove that expectation. If the test publishes a retained `PeerList` to `devicePeers` and checks the handler, the test needs to be rewritten to mock a `FetchPeersResult` response via RPC OR delete the test entirely — the retained path is gone.

For MVP: if the test is purely about "subscribe_all subscribes to these topics", update the expected topic set. Detailed RPC-mocking tests can be deferred; the existing integration coverage via Phase 2a iOS build checks is sufficient.

- [ ] **Step 7: Commit**

```bash
cd /Volumes/openbeta/workspace/amux && git add ios/Packages/AMUXCore/Sources/AMUXCore/TeamclawService.swift ios/Packages/AMUXCore/Tests/AMUXCoreTests/TeamclawServiceSubscriptionTests.swift && git commit -m "$(cat <<'EOF'
feat(ios): TeamclawService uses FetchPeers RPC instead of retained devicePeers

Drops the devicePeers subscribe and retained-payload handler. On MQTT
connect, calls fetchPeers() and pipes the result through the same sync
target the retained handler used today. On Notify{event_type:
"peers.changed" | "members.changed"}, re-calls fetchPeers() for a
refresh. Tests updated for the new subscribe set.

Daemon still publishes the retained devicePeers topic for pre-Phase-2b
iOS clients; Phase 3 retires it.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: iOS — `SessionListViewModel` uses FetchWorkspaces RPC

**Files:**
- Modify: `ios/Packages/AMUXCore/Sources/AMUXCore/ViewModels/SessionListViewModel.swift`
- Modify: `ios/Packages/AMUXCore/Sources/AMUXCore/TeamclawService.swift` (notify-handler wiring for `workspaces.changed`)

Currently `SessionListViewModel.swift:69` builds `deviceWorkspaces` topic and subscribes at line 98, handles retained `WorkspaceList` around line 103-110. Switch to: call `teamclawService.fetchWorkspaces()` on start (instead of subscribing) + receive workspace updates via a notification or callback when notify-driven refresh fires.

Simplest integration: `SessionListViewModel` gets a reference to `TeamclawService` (likely already has one or can accept one in its `start(...)` signature). On start, calls `fetchWorkspaces()` directly. For notify-driven refresh, add an async notify-tap that triggers a refetch — either via a delegate/callback on TeamclawService or via a shared `@Observable` workspaces source.

The complexity here depends on how state flows today. Simplest path: on start, `SessionListViewModel` kicks off a task that (a) calls `fetchWorkspaces()`, (b) loops listening for the MQTT message stream, (c) for each `device/{id}/notify` message with `event_type == "workspaces.changed"`, re-calls `fetchWorkspaces()`. This mirrors the existing pattern in the file (which already has an MQTT message-stream loop).

- [ ] **Step 1: Remove `deviceWorkspaces` subscribe + retained-payload handler**

In `SessionListViewModel.swift`, find:

```swift
        let workspacesTopic = MQTTTopics.deviceWorkspaces(teamID: teamID, deviceID: deviceId)
```
Delete.

In the subscribe block (around line 98):
```swift
                try? await mqtt.subscribe(workspacesTopic)
```
Delete.

Update the NSLog line — drop the `workspacesTopic` reference:
```swift
                NSLog("[SessionListVM] subscribed to %@", runtimeStateWildcard)
```

Find the retained-payload handler (around line 103-110):

```swift
                    if msg.topic == workspacesTopic {
                        NSLog("[SessionListVM] received workspaces msg, %d bytes", msg.payload.count)
                        if let list = try? ProtoMQTTCoder.decode(Amux_WorkspaceList.self, from: msg.payload) {
                            NSLog("[SessionListVM] decoded WorkspaceList: %d workspaces", list.workspaces.count)
                            syncWorkspaces(list, modelContext: ctx)
                        } else {
                            NSLog("[SessionListVM] FAILED to decode WorkspaceList")
                        }
                        continue
                    }
```

Delete the entire `if msg.topic == workspacesTopic` block. `syncWorkspaces(_:modelContext:)` stays — it's still useful, called from the new RPC path.

- [ ] **Step 2: Adjust `syncWorkspaces` to accept `[Amux_WorkspaceInfo]` instead of `Amux_WorkspaceList`**

Current signature probably takes the list wrapper. Change to take the array directly so it matches both the old `list.workspaces` and the new `FetchWorkspacesResult.workspaces`:

```swift
    private func syncWorkspaces(_ workspaces: [Amux_WorkspaceInfo], modelContext: ModelContext) {
        // body stays the same, but the outer fetch from `list.workspaces` is
        // now just `workspaces` directly
    }
```

Update the old call site (in the retained-payload handler — which you just deleted — but if there's any other retained path, update it too) accordingly.

Actually since we're deleting the retained handler, the only remaining callers of `syncWorkspaces` are the new ones you'll add in the next step. So the rename is free.

- [ ] **Step 3: Call `fetchWorkspaces()` on connect + re-fetch on notify**

The existing stream loop in `SessionListViewModel` subscribes and processes messages. It can't know about `workspaces.changed` notifies directly — TeamclawService owns the notify topic. Two options:

**Option A (simpler):** add a public `@Observable` property on TeamclawService like `@Published var workspacesVersion: Int = 0` that increments on each `workspaces.changed` notify. SessionListViewModel watches this and refetches.

**Option B (cleaner but bigger):** TeamclawService exposes an AsyncStream of workspace-change events. SessionListViewModel awaits on it.

**Option C (minimum change):** call `fetchWorkspaces()` once on connect inside SessionListViewModel; for ongoing updates, rely on mutations being initiated from the same iOS session that already triggers a local refresh. Phase 2c's workspace-mutation switchover (AddWorkspace/RemoveWorkspace RPC) can directly call `syncWorkspaces` in its success handler.

For Phase 2b MVP, use **Option C**: one-shot fetch on connect, no notify-driven refresh. Comment the gap for Phase 2c.

Implementation in SessionListViewModel's start() method, right after successful subscribe to `runtimeStateWildcard`:

```swift
                // Phase 2b: workspaces come from FetchWorkspaces RPC instead
                // of retained topic subscription. One-shot fetch on connect.
                // Phase 2c will call syncWorkspaces from workspace-mutation
                // success handlers; until then, users don't see changes made
                // from other devices until they reconnect. Acceptable for
                // the compat window.
                Task { [weak self] in
                    guard let self else { return }
                    let workspaces = await teamclawService.fetchWorkspaces()
                    await MainActor.run {
                        self.syncWorkspaces(workspaces, modelContext: ctx)
                    }
                }
```

`SessionListViewModel` needs a `teamclawService: TeamclawService` reference. If its `start(...)` signature doesn't already accept one, add it:

```swift
    public func start(
        mqtt: MQTTService,
        teamID: String = "",
        deviceId: String,
        modelContext: ModelContext,
        teamclawService: TeamclawService
    ) {
        // ... existing body ...
    }
```

And store it as a property so the task closure above can capture it. Update all call sites (a couple in AMUXUI — grep for `SessionListViewModel()` or `.start(mqtt:...)` to find them) to pass the shared `TeamclawService`.

**If wiring TeamclawService into SessionListViewModel is too invasive for this plan, choose Option A (expose a refetch trigger and have SessionListViewModel react to it). Either is acceptable — pick the smaller diff.**

- [ ] **Step 4: Verify iOS compiles**

```bash
cd /Volumes/openbeta/workspace/amux/ios && xcodebuild -project AMUX.xcodeproj -scheme AMUX -destination 'generic/platform=iOS' -configuration Debug build CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "BUILD SUCCEEDED|BUILD FAILED|error:" | head -5
```

Expected: `** BUILD SUCCEEDED **`. If call sites of `SessionListViewModel().start(...)` need updating (signature changed), fix them — likely 1-2 sites in `AMUXUI`.

- [ ] **Step 5: Commit**

```bash
cd /Volumes/openbeta/workspace/amux && git add ios/Packages/AMUXCore/Sources/AMUXCore/ViewModels/SessionListViewModel.swift && git add ios/Packages/AMUXUI/Sources/AMUXUI 2>/dev/null || true && git commit -m "$(cat <<'EOF'
feat(ios): SessionListViewModel uses FetchWorkspaces RPC on connect

Drops the deviceWorkspaces retained topic subscribe and its handler.
Calls teamclawService.fetchWorkspaces() once on connect and pipes the
result through syncWorkspaces. Notify-driven refresh (workspaces.changed)
is a Phase 2c followup — for now, workspace changes from other devices
aren't seen until reconnect. Acceptable for the compat window since
Phase 2b daemon still publishes retained deviceWorkspaces for legacy
iOS clients.

syncWorkspaces signature changed to accept [Amux_WorkspaceInfo]
directly instead of Amux_WorkspaceList, matching both the old
list.workspaces and new FetchWorkspacesResult.workspaces shape.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

Note: the `git add ios/Packages/AMUXUI/Sources/AMUXUI 2>/dev/null || true` is defensive — if no AMUXUI call sites needed updating, the command still succeeds. Only actual modifications get staged.

---

## Task 7: Final verification

**Files:** none (verification only)

- [ ] **Step 1: Full daemon + iOS clean build + tests**

```bash
cd /Volumes/openbeta/workspace/amux/daemon && cargo clean 2>&1 | tail -2
cd /Volumes/openbeta/workspace/amux/daemon && set -a && source .env && set +a && cargo build 2>&1 | tail -3 && cargo test --no-fail-fast 2>&1 | grep "cargo test:" | tail -1
cd /Volumes/openbeta/workspace/amux/ios && xcodebuild -project AMUX.xcodeproj -scheme AMUX -destination 'generic/platform=iOS' -configuration Debug clean build CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "BUILD SUCCEEDED|BUILD FAILED" | head -2
```
Expected: daemon 104+ pass, iOS SUCCEEDED.

- [ ] **Step 2: Confirm peers/workspaces retained subscriptions are gone**

```bash
cd /Volumes/openbeta/workspace/amux && grep -n "devicePeers\|deviceWorkspaces" ios/Packages/AMUXCore/Sources/AMUXCore/TeamclawService.swift ios/Packages/AMUXCore/Sources/AMUXCore/ViewModels/SessionListViewModel.swift
```
Expected: zero hits (both consumers migrated to RPC).

- [ ] **Step 3: Confirm FetchPeers / FetchWorkspaces RPC call sites exist**

```bash
grep -rn "fetchPeers\|fetchWorkspaces" ios/Packages --include='*.swift' | grep -v .pb.swift | head
```
Expected: definitions in `TeamclawService.swift` + call sites in `TeamclawService.swift` (on connect + notify) and `SessionListViewModel.swift` (on connect).

- [ ] **Step 4: Confirm daemon `NotifyPublisher` uses `Notify`, decoder handles both**

```bash
grep -n "Notify\b\|NotifyEnvelope" daemon/src/teamclaw/notify.rs
grep -n "Notify::decode\|NotifyEnvelope::decode" daemon/src/daemon/server.rs
```
Expected: `notify.rs` only references `Notify` (not `NotifyEnvelope`); `server.rs` references both (compat decoder).

- [ ] **Step 5: Commit sequence review**

```bash
cd /Volumes/openbeta/workspace/amux && git log --oneline 584556e0..HEAD
```
Expected: 5 commits — `docs(mqtt): add phase-2b plan...`, `refactor(notify): migrate NotifyPublisher...`, `feat(ios): add fetchPeers / fetchWorkspaces RPC helpers`, `feat(ios): decode Notify + NotifyEnvelope on deviceNotify`, `feat(ios): TeamclawService uses FetchPeers RPC...`, `feat(ios): SessionListViewModel uses FetchWorkspaces RPC on connect`. (Actual count: 6 including the plan commit.)

- [ ] **Step 6: Working tree clean**

```bash
cd /Volumes/openbeta/workspace/amux && git status --porcelain
```
Expected: only pre-existing user state (mac/Packages unresolved conflict markers, untracked `ios/AMUXUITests/`, `scripts/run-ios.sh`).

---

## Phase 2b Complete

At this point:
- Daemon's `NotifyPublisher::publish_membership_refresh` emits `Teamclaw_Notify` (uniform with Phase 1b `Publisher::publish_notify`). `NotifyEnvelope` is decoded for compat.
- iOS decodes both `Notify` and `NotifyEnvelope` on `deviceNotify`; `membership.refresh` / `members.changed` / `peers.changed` / `workspaces.changed` all routed.
- iOS `TeamclawService.fetchPeers()` and `fetchWorkspaces()` RPC helpers exist and are called on connect + (for peers) on notify.
- iOS no longer subscribes to retained `device/{id}/peers` or `device/{id}/workspaces` topics.
- Daemon still publishes both retained topics for pre-Phase-2b iOS clients. Phase 3 retires them.
- iOS mutations for peers/workspaces/members still flow through `/collab`. Phase 2c migrates them to RPC.
- SwiftData `Agent` model and MQTTTopics legacy methods unchanged. Phase 2d handles those.

**Next plan (Phase 2c):** iOS mutations migration — `WorkspaceManagementView.swift`, `MemberListContent.swift`, `NewSessionSheet.swift` switch collab-op publishes from `device/{id}/collab` to `rpc/req` using the handlers landed in Phase 1b. Also: iOS adopts `RuntimeStart` RPC for the new-session flow (replacing `AcpCommand::StartAgent` via `CommandEnvelope`), unlocking the STARTING/ACTIVE lifecycle UI from Phase 1c.

**Phase 2d (future):** SwiftData `Agent` → `Runtime` rename (destructive reset per spec default), ViewModel/View class renames, delete legacy `MQTTTopics.swift` methods.

**Phase 1d (gated):** `user/{actor}/notify` subscribe + outbox, after Supabase `user_inbox` + EMQX JWT prereqs.
