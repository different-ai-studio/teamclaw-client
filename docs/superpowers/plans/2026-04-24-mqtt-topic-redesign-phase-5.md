# Phase 5 — Delete Legacy Proto Messages

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development.

**Goal:** Delete the proto messages that are no longer wire-active after Phases 1–4. Regenerate Swift + Rust proto code. Remove dual-decoder fallbacks.

**Architecture:** Three tasks:
1. Daemon: remove `CommandEnvelope` translation shim in `handle_incoming` — route `RuntimeCommandEnvelope` directly; drop NotifyEnvelope dual-decoder fallback.
2. iOS: remove `NotifyEnvelope` fallback in `TeamclawService`.
3. Proto: delete messages from `.proto` files, regenerate both sides, verify zero build regressions.

**Types to delete (proto/amux.proto + proto/teamclaw.proto):**
- `CommandEnvelope` (legacy 1:1 of RuntimeCommandEnvelope)
- `DeviceCommandEnvelope` (legacy /collab upstream envelope)
- `DeviceCollabEvent` (legacy /collab downstream event)
- `DeviceCollabCommand` (legacy /collab command oneof)
- `LegacyAgentStartResult` (only used inside DeviceCollabEvent.agent_start_result)
- `NotifyEnvelope` (legacy notify wire shape; Notify is the new shape)
- Orphaned-after-DeviceCollabEvent-delete: `PeerJoined`, `PeerLeft`, `PeerKicked`, `MemberListChanged`, `AuthResult`, `InviteCreated`, `WorkspaceResult`
- Orphaned-after-DeviceCollabCommand-delete: `PeerDisconnect` (empty message), `InviteMember`

**Types to KEEP (still used as internal Rust command objects in daemon handlers):**
- `PeerAnnounce` — used by `handle_announce_peer` as payload wrapper
- `RemoveMember`, `AddWorkspace`, `RemoveWorkspace` — used by `handle_*` RPC handlers as internal pass-through payloads to `apply_*`
- `PromptAccepted`, `PromptRejected` — still used in active `CollabEvent`

**Tech Stack:** Proto3 (prost-build, swift-protobuf). Regenerate with `cargo build` (Rust auto) and `./scripts/proto-gen-swift.sh` (iOS manual).

---

### Task 1: Daemon — remove CommandEnvelope translation shim + NotifyEnvelope fallback

**Files:** `daemon/src/daemon/server.rs`

- [ ] **Step 1:** Find the RuntimeCommand translation shim (~line 626):
```rust
subscriber::IncomingMessage::RuntimeCommand { runtime_id, envelope } => {
    let legacy_envelope = amux::CommandEnvelope {
        runtime_id: envelope.runtime_id,
        device_id: envelope.device_id,
        peer_id: envelope.peer_id,
        command_id: envelope.command_id,
        timestamp: envelope.timestamp,
        sender_actor_id: envelope.sender_actor_id,
        reply_to_device_id: envelope.reply_to_device_id,
        acp_command: envelope.acp_command,
    };
    self.handle_agent_command(&runtime_id, legacy_envelope).await;
}
```
Replace with:
```rust
subscriber::IncomingMessage::RuntimeCommand { runtime_id, envelope } => {
    self.handle_agent_command(&runtime_id, envelope).await;
}
```

Update the signature of `handle_agent_command`:
```rust
// was: fn handle_agent_command(&mut self, agent_id: &str, envelope: amux::CommandEnvelope)
async fn handle_agent_command(&mut self, agent_id: &str, envelope: amux::RuntimeCommandEnvelope) {
```

Since `CommandEnvelope` and `RuntimeCommandEnvelope` have the same field names, the function body needs no further edits.

- [ ] **Step 2:** Find the TeamclawNotify dual-decoder (~line 727–736):
```rust
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
```
Simplify to single-shape decode:
```rust
let parsed: Option<(String, String)> = match crate::proto::teamclaw::Notify::decode(payload.as_slice()) {
    Ok(n) => Some((n.event_type, n.refresh_hint)),
    Err(_) => {
        warn!("failed to decode device/notify payload as Notify");
        None
    }
};
```

- [ ] **Step 3:** Build and test:
```bash
cd /Volumes/openbeta/workspace/amux
export SUPABASE_URL="https://srhaytajyfrniuvnkfpd.supabase.co/rest/v1/"
export SUPABASE_ANON_KEY="sb_publishable_CJavqYCusEBD7cIebhH5tQ_K_I9AXpE"
cd daemon && cargo build 2>&1 | tail -10
cargo test 2>&1 | tail -10
```
Expected: clean build, 98 tests pass.

- [ ] **Step 4:** Commit:
```bash
cd /Volumes/openbeta/workspace/amux
git add daemon/src/daemon/server.rs
git commit -m "refactor(daemon): drop CommandEnvelope shim + NotifyEnvelope dual-decoder"
```

---

### Task 2: iOS — remove NotifyEnvelope fallback

**Files:** `ios/Packages/AMUXCore/Sources/AMUXCore/TeamclawService.swift`

- [ ] **Step 1:** Find the notify handler (~line 122–155). Currently tries `Teamclaw_Notify` then falls back to `Teamclaw_NotifyEnvelope`. Simplify:
```swift
if topic == MQTTTopics.deviceNotify(teamID: teamId, deviceID: deviceId) {
    guard let notify = try? Teamclaw_Notify(serializedBytes: incoming.payload) else {
        print("[TeamclawService] failed to decode device/notify payload as Notify")
        return
    }

    switch notify.eventType {
    case "membership.refresh", "members.changed":
        if !notify.refreshHint.isEmpty {
            await refreshSessionState(for: notify.refreshHint, modelContext: modelContext)
        }
    case "peers.changed":
        let peers = await fetchPeers()
        syncPeers(peers)
    case "workspaces.changed":
        _ = await fetchWorkspaces()
    default:
        break
    }
    return
}
```

- [ ] **Step 2:** Build iOS:
```bash
cd /Volumes/openbeta/workspace/amux/ios && xcodebuild -scheme AMUX -destination 'platform=iOS Simulator,name=iPhone 17' build 2>&1 | tail -30
```
Expected: BUILD SUCCEEDED. (The `Teamclaw_NotifyEnvelope` type is still in the generated proto file at this point, so no compile error from referencing it in deleted code.)

- [ ] **Step 3:** Commit:
```bash
cd /Volumes/openbeta/workspace/amux
git add ios/Packages/AMUXCore/Sources/AMUXCore/TeamclawService.swift
git commit -m "refactor(ios): drop NotifyEnvelope fallback in TeamclawService notify handler"
```

---

### Task 3: Delete proto messages + regenerate

**Files:** `proto/amux.proto`, `proto/teamclaw.proto`, then auto-regenerated Rust (`daemon/build.rs`) and Swift (`./scripts/proto-gen-swift.sh`).

- [ ] **Step 1:** Edit `proto/amux.proto`. Delete these message definitions:
- `CommandEnvelope` (~line 23)
- `DeviceCommandEnvelope` (~line 58)
- `DeviceCollabEvent` (~line 224)
- `DeviceCollabCommand` (~line 280)
- `LegacyAgentStartResult` (~line 310)
- `PeerJoined`, `PeerLeft`, `PeerKicked`, `MemberListChanged`, `AuthResult`, `InviteCreated`, `WorkspaceResult`, `PeerDisconnect`, `InviteMember`

**KEEP:** `PeerAnnounce`, `RemoveMember`, `AddWorkspace`, `RemoveWorkspace`, `PromptAccepted`, `PromptRejected`, `CollabEvent`, `HistoryBatch`, `PermissionResolved`, and everything else.

- [ ] **Step 2:** Edit `proto/teamclaw.proto`. Delete `NotifyEnvelope` (~line 132).

- [ ] **Step 3:** Regenerate Rust:
```bash
cd /Volumes/openbeta/workspace/amux
export SUPABASE_URL="https://srhaytajyfrniuvnkfpd.supabase.co/rest/v1/"
export SUPABASE_ANON_KEY="sb_publishable_CJavqYCusEBD7cIebhH5tQ_K_I9AXpE"
cd daemon && cargo build 2>&1 | tail -20
```
This triggers `build.rs` → prost-build regenerates `amux.rs`/`teamclaw.rs` under `target/debug/build/amuxd-*/out/`. Inspect the tail for compile errors:
- Any remaining `amux::DeviceCollabEvent` / `amux::CommandEnvelope` etc references will fail. Expected callers were all cleaned in Phases 1-4+Task 1; grep remainders:
  ```bash
  /usr/bin/grep -rn "amux::CommandEnvelope\|amux::DeviceCommandEnvelope\|amux::DeviceCollabEvent\|amux::DeviceCollabCommand\|amux::LegacyAgentStartResult\|amux::PeerJoined\|amux::PeerLeft\|amux::PeerKicked\|amux::MemberListChanged\|amux::AuthResult\|amux::InviteCreated\|amux::WorkspaceResult\|amux::PeerDisconnect\|amux::InviteMember\|teamclaw::NotifyEnvelope" daemon/src
  ```
  Expected: zero matches. If any remain, fix them (remove the dead code or update imports).

- [ ] **Step 4:** Regenerate Swift:
```bash
cd /Volumes/openbeta/workspace/amux && ./scripts/proto-gen-swift.sh
```
(Verify the script exists and runs cleanly. If it has different name/location, adjust.) The script overwrites `ios/Packages/AMUXCore/Sources/AMUXCore/Proto/amux.pb.swift` and `teamclaw.pb.swift`.

After regen, build iOS:
```bash
cd /Volumes/openbeta/workspace/amux/ios && xcodebuild -scheme AMUX -destination 'platform=iOS Simulator,name=iPhone 17' build 2>&1 | tail -30
```
Expected: BUILD SUCCEEDED. Any remaining `Amux_DeviceCollabEvent` / `Amux_CommandEnvelope` etc references in iOS non-generated code will fail — these should all have been removed in Phase 2c (verify with a grep).

Final iOS verification grep:
```bash
/usr/bin/grep -rln "Amux_CommandEnvelope\|Amux_DeviceCommandEnvelope\|Amux_DeviceCollabEvent\|Amux_DeviceCollabCommand\|Amux_LegacyAgentStartResult\|Amux_PeerJoined\|Amux_PeerLeft\|Amux_PeerKicked\|Amux_MemberListChanged\|Amux_AuthResult\|Amux_InviteCreated\|Amux_WorkspaceResult\|Amux_PeerDisconnect\|Amux_InviteMember\|Teamclaw_NotifyEnvelope" ios/Packages
```
Expected: zero matches (except the pb.swift files which are overwritten by regen).

- [ ] **Step 5:** Run final daemon tests:
```bash
cd /Volumes/openbeta/workspace/amux/daemon && cargo test 2>&1 | tail -10
```
Expected: 98 pass.

- [ ] **Step 6:** Commit proto deletes + regenerated files:
```bash
cd /Volumes/openbeta/workspace/amux
git add proto/amux.proto proto/teamclaw.proto ios/Packages/AMUXCore/Sources/AMUXCore/Proto/amux.pb.swift ios/Packages/AMUXCore/Sources/AMUXCore/Proto/teamclaw.pb.swift
git commit -m "feat(proto): delete legacy messages (CommandEnvelope, DeviceCollab*, NotifyEnvelope, etc.); regenerate Swift"
```

(Rust generated files live under `target/` and are not checked in; prost regenerates them on each `cargo build`.)
