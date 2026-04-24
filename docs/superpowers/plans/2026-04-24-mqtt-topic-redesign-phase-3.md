# Phase 3 — Daemon Retires Legacy Topics

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox `- [ ]` syntax.

**Goal:** Daemon stops subscribing/publishing on the legacy topics that iOS Phases 1+2 already migrated off of. LWT atomically retargets from `device/{id}/status` to `device/{id}/state`. Dual-publish/dual-subscribe windows close.

**Architecture:** Strictly mechanical — drop legacy publish branches, drop subscribes, drop dead receive paths, retarget LWT. No new types. No proto changes. No internal renames (those are Phase 4).

**Tech Stack:** Rust 2021, prost, rumqttc, tokio. All daemon-side.

**Pre-req confirmed:** iOS Phase 2c done (commits up to `7746b4be`); iOS no longer publishes on `device/{id}/collab`, `agent/{new}/commands`, and no longer relies on retained `device/{id}/peers` / `device/{id}/workspaces` / `agent/+/state`. iOS dual-subscribes `status`+`state` (Phase 1a) so retargeting LWT is safe.

---

## Files

- Modify: `daemon/src/mqtt/client.rs` — subscribe_all, announce_online, LWT
- Modify: `daemon/src/mqtt/publisher.rs` — drop legacy mirror publishes; delete helpers that only published to retired topics
- Modify: `daemon/src/mqtt/topics.rs` — delete legacy topic builders; update tests
- Modify: `daemon/src/mqtt/subscriber.rs` — drop receive paths for retired topics (DeviceCollab, AgentCommand)
- Modify: `daemon/src/daemon/server.rs` — drop `handle_device_collab`, `publish_command_rejected`, `publish_agent_start_result`, `handle_agent_command` (the legacy path), `publish_peer_list`/`publish_workspace_list` call sites; collab arm in `handle_incoming` deleted; AgentCommand arm in `handle_incoming` deleted
- Modify: `daemon/src/cli/test_client.rs` — switch subscribes to new topics; update or remove tests that hit the deleted command path

---

### Task 1: Stop subscribing to legacy command + collab topics

**Files:** `daemon/src/mqtt/client.rs`, `daemon/src/mqtt/subscriber.rs`, `daemon/src/daemon/server.rs`

- [ ] **Step 1:** In `daemon/src/mqtt/client.rs`, simplify `subscribe_all` to only subscribe to `runtime_commands_wildcard`. Drop the subscribes for `topics.collab()` and `topics.all_agent_commands()`.

```rust
pub async fn subscribe_all(&self) -> Result<(), rumqttc::ClientError> {
    self.client
        .subscribe(self.topics.runtime_commands_wildcard(), QoS::AtLeastOnce)
        .await?;
    info!(
        "subscribed to {}",
        self.topics.runtime_commands_wildcard(),
    );
    Ok(())
}
```

- [ ] **Step 2:** In `daemon/src/mqtt/subscriber.rs`, locate the variants `IncomingMessage::AgentCommand` and `IncomingMessage::DeviceCollab` plus their parser arms. Delete:
- The `AgentCommand { agent_id, envelope }` variant
- The `DeviceCollab { envelope }` variant
- The parser arms that produce them (any `if topic.contains("/agent/") && topic.ends_with("/commands")` branch and any `if topic.ends_with("/collab")` branch)

If parser uses `match` over topic patterns, drop the matching arms. Keep RuntimeCommand, TeamclawRpc, TeamclawSessionLive, TeamclawNotify.

- [ ] **Step 3:** In `daemon/src/daemon/server.rs`, in `handle_incoming` (~line 620), delete the two arms:
```rust
subscriber::IncomingMessage::AgentCommand { agent_id, envelope } => {
    self.handle_agent_command(&agent_id, envelope).await;
}
```
and
```rust
subscriber::IncomingMessage::DeviceCollab { envelope } => {
    self.handle_device_collab(envelope).await;
}
```

The `RuntimeCommand` arm (just below) translates to a legacy `CommandEnvelope` and calls `handle_agent_command(&runtime_id, ...)`. Keep this arm and `handle_agent_command` itself for now (Phase 4 will rename and Phase 5 unifies envelopes). The translation shim stays.

- [ ] **Step 4:** Build and run tests with env vars exported:
```bash
cd /Volumes/openbeta/workspace/amux
export SUPABASE_URL="https://srhaytajyfrniuvnkfpd.supabase.co/rest/v1/"
export SUPABASE_ANON_KEY="sb_publishable_CJavqYCusEBD7cIebhH5tQ_K_I9AXpE"
cd daemon && cargo build 2>&1 | tail -20
```
Expected: clean build (warnings about unused fields/code in publisher.rs/server.rs are OK — Tasks 2-5 clean those up).

- [ ] **Step 5:** Commit.
```bash
cd /Volumes/openbeta/workspace/amux
git add daemon/src/mqtt/client.rs daemon/src/mqtt/subscriber.rs daemon/src/daemon/server.rs
git commit -m "refactor(daemon): stop subscribing to legacy /collab and /agent/+/commands topics"
```

---

### Task 2: Delete the device-collab event publishers + handler

**Files:** `daemon/src/mqtt/publisher.rs`, `daemon/src/mqtt/topics.rs`, `daemon/src/daemon/server.rs`

- [ ] **Step 1:** In `daemon/src/mqtt/publisher.rs`, delete:
- `pub async fn publish_device_collab_event(...)` (~lines 58–62)
- `pub async fn publish_device_collab_event_to(...)` (~lines 64–68)

- [ ] **Step 2:** In `daemon/src/daemon/server.rs`, delete:
- `async fn handle_device_collab(&mut self, envelope: amux::DeviceCommandEnvelope)` (~lines 1091–1168)
- `async fn publish_command_rejected(&self, reply_device_id: &str, command_id: String, reason: String)` (~lines 1184–1195)
- `async fn publish_agent_start_result(...)` (~lines 1197–1226) — only callers were inside `handle_agent_command`'s legacy reject paths and `handle_device_collab`. Both gone.
- The two free helper fns at the bottom of the file: `command_rejected_event(...)` and `agent_start_result_event(...)` — verify by grep that no remaining caller exists.

```bash
/usr/bin/grep -n "command_rejected_event\|agent_start_result_event\|publish_command_rejected\|publish_agent_start_result\|publish_device_collab_event\|handle_device_collab" daemon/src
```

If any references remain, it's likely inside `handle_agent_command`. Inspect that function — it currently uses these helpers to NACK rejected ACP commands. Since the AcpCommand::StartAgent path is dead in Phase 3 (iOS uses RuntimeStart RPC), only ACP prompt/permission paths remain. Those don't need `device_collab_event_to` — they just discard rejected envelopes (or they may not exist anymore). Audit the function and drop any remaining callers; if the function uses `publish_command_rejected` for a real path, replace it with a `warn!` log and a return.

- [ ] **Step 3:** In `daemon/src/mqtt/topics.rs`, delete:
- `pub fn collab(&self) -> String` (~lines 31–33)
- `pub fn collab_for(&self, device_id: &str) -> String` (~lines 35–37)

Update the `legacy_paths_still_work` test (lines ~172–196) — remove the assertion for `t.collab()`.

- [ ] **Step 4:** Build and check for unused-import warnings (`amux::DeviceCommandEnvelope`, `amux::DeviceCollabEvent` may now be unused in some files — that's fine, Phase 5 deletes them). Run tests:
```bash
cd /Volumes/openbeta/workspace/amux/daemon && cargo test 2>&1 | tail -10
```
Expected: 104 tests pass (or new count if you removed legacy_paths_still_work assertions).

- [ ] **Step 5:** Commit.
```bash
git add daemon/src/mqtt/publisher.rs daemon/src/mqtt/topics.rs daemon/src/daemon/server.rs
git commit -m "refactor(daemon): delete device/collab handler + publishers + topic builders"
```

---

### Task 3: Drop publish_peer_list / publish_workspace_list (retained list publishes)

**Files:** `daemon/src/mqtt/publisher.rs`, `daemon/src/mqtt/topics.rs`, `daemon/src/daemon/server.rs`

- [ ] **Step 1:** In `daemon/src/daemon/server.rs`, find every call to `publish_peer_list` and `publish_workspace_list`:
```bash
/usr/bin/grep -n "publish_peer_list\|publish_workspace_list" daemon/src/daemon/server.rs
```

For each call site, delete the call. Check the surrounding context — the AddWorkspace / RemoveWorkspace / AnnouncePeer / DisconnectPeer / RemoveMember handlers already follow each list publish with a `publish_notify("peers.changed", "")` or `("workspaces.changed", "")`. The notify is the new client trigger; iOS re-fetches via FetchPeers/FetchWorkspaces RPC (Phase 2b).

If a call site does NOT have a paired notify (e.g., during initial connect or after StoredSession reload), insert one. Pattern:
```rust
let publisher = Publisher::new(&self.mqtt);
let _ = publisher.publish_notify("peers.changed", "").await;
// or "workspaces.changed"
```

The connect path (server.rs:152–156) currently publishes both lists at startup. Replace with two notify hints (peers.changed + workspaces.changed) — or omit them entirely if iOS proactively fetches on connect (verify with TeamclawService.start: yes, it does — it calls fetchPeers + fetchWorkspaces on MQTT connect). Drop the startup list-publishes entirely.

- [ ] **Step 2:** In `daemon/src/mqtt/publisher.rs`, delete:
- `pub async fn publish_peer_list(...)` (~lines 14–18)
- `pub async fn publish_workspace_list(...)` (~lines 70–74)

- [ ] **Step 3:** In `daemon/src/mqtt/topics.rs`, delete:
- `pub fn peers(&self) -> String` (~lines 23–25)
- `pub fn workspaces(&self) -> String` (~lines 27–29)

Update `legacy_paths_still_work` to drop assertions for `peers()` and `workspaces()`.

- [ ] **Step 4:** Build and test.
```bash
cd /Volumes/openbeta/workspace/amux/daemon && cargo test 2>&1 | tail -10
```
Expected: tests pass (count may change if legacy_paths_still_work removed entirely).

- [ ] **Step 5:** Commit.
```bash
git add daemon/src/mqtt/publisher.rs daemon/src/mqtt/topics.rs daemon/src/daemon/server.rs
git commit -m "refactor(daemon): drop /peers and /workspaces retained lists; rely on notify"
```

---

### Task 4: Single-publish runtime state/events/clear (drop legacy mirror)

**Files:** `daemon/src/mqtt/publisher.rs`, `daemon/src/mqtt/topics.rs`

- [ ] **Step 1:** In `daemon/src/mqtt/publisher.rs`:

`publish_agent_state` currently publishes to BOTH `topics.agent_state(agent_id)` and `topics.runtime_state(agent_id)`. Drop the agent_state publish; keep runtime_state only:

```rust
/// Publishes RuntimeInfo to the retained runtime/{id}/state topic.
/// (Legacy agent/{id}/state publish dropped in Phase 3.)
pub async fn publish_agent_state(&self, agent_id: &str, info: &amux::RuntimeInfo) -> Result<(), rumqttc::ClientError> {
    self.client.client
        .publish(self.client.topics.runtime_state(agent_id), QoS::AtLeastOnce, true, info.encode_to_vec())
        .await
}
```

Same for `publish_agent_event`:
```rust
/// Publishes Envelope to the runtime/{id}/events topic. Ephemeral (no retain).
pub async fn publish_agent_event(&self, agent_id: &str, envelope: &amux::Envelope) -> Result<(), rumqttc::ClientError> {
    self.client.client
        .publish(self.client.topics.runtime_events(agent_id), QoS::AtLeastOnce, false, envelope.encode_to_vec())
        .await
}
```

Same for `clear_agent_state`:
```rust
/// Clears retained state on runtime/{id}/state. (Legacy agent/{id}/state clear dropped in Phase 3.)
pub async fn clear_agent_state(&self, agent_id: &str) -> Result<(), rumqttc::ClientError> {
    self.client.client
        .publish(self.client.topics.runtime_state(agent_id), QoS::AtLeastOnce, true, Vec::<u8>::new())
        .await
}
```

(Function names stay `publish_agent_state` / `publish_agent_event` / `clear_agent_state` — Phase 4 renames them. Keeping names stable here keeps Phase 3 strictly transport-only.)

- [ ] **Step 2:** In `daemon/src/mqtt/topics.rs`, delete:
- `pub fn agent_state(&self, agent_id: &str)`
- `pub fn agent_events(&self, agent_id: &str)`
- `pub fn agent_commands(&self, agent_id: &str)`
- `pub fn all_agent_commands(&self)`

Update `legacy_paths_still_work` test to drop or replace assertions for these.

- [ ] **Step 3:** Build and test.
```bash
cd /Volumes/openbeta/workspace/amux/daemon && cargo test 2>&1 | tail -10
```

If `cargo build` fails because some other code still calls `topics.agent_state(...)` etc., search and fix:
```bash
/usr/bin/grep -rn "topics\.agent_state\|topics\.agent_events\|topics\.agent_commands\|topics\.all_agent_commands" daemon/src
```

The only remaining live caller of these would be `daemon/src/cli/test_client.rs:251,391` — Task 6 fixes that. If Task 4 leaves test_client uncompilable temporarily, that's OK — the daemon binary still builds.

Actually, `cargo build` builds everything including bins. If test_client breaks, Task 4's commit is broken. Either:
- (a) Land Task 4 + Task 6 atomically, OR
- (b) In Task 4, also patch test_client.rs:251 and :391 to use `topics.runtime_commands(runtime_id)` for the immediate compilability fix; Task 6 then handles the broader test_client cleanup.

Choose option (b) — minimal patch: replace `tc.topics.agent_commands("new")` with `tc.topics.runtime_commands("new")` at both sites. Same arity, same semantics for the test-driver case.

- [ ] **Step 4:** Commit.
```bash
git add daemon/src/mqtt/publisher.rs daemon/src/mqtt/topics.rs daemon/src/cli/test_client.rs
git commit -m "refactor(daemon): single-publish runtime state/events; drop legacy /agent/+/* paths"
```

---

### Task 5: LWT retarget + drop /status

**Files:** `daemon/src/mqtt/client.rs`, `daemon/src/mqtt/publisher.rs`, `daemon/src/mqtt/topics.rs`

This is the riskiest task in Phase 3 — it changes how iOS detects daemon offline. Pre-req confirmed: iOS ConnectionMonitor (Phase 1a) dual-subscribes `device/{id}/status` AND `device/{id}/state`, with offline-wins merge. After this task, daemon publishes only to `/state`; iOS `/status` subscription becomes dead but harmless (no payloads arrive). iOS-side cleanup of the dead subscription is out of scope for Phase 3 — Phase 2d (the iOS rename phase) handles it.

- [ ] **Step 1:** In `daemon/src/mqtt/client.rs`:

Change the LWT topic from `topics.status()` to `topics.device_state()`:
```rust
// LWT now fires on device/{id}/state — Phase 3 retired /status.
let lwt = rumqttc::LastWill::new(
    topics.device_state(),
    lwt_payload.encode_to_vec(),
    QoS::AtLeastOnce,
    true,
);
opts.set_last_will(lwt);
```

Change `announce_online` to publish to `device_state`:
```rust
pub async fn announce_online(&self, device_name: &str) -> Result<(), rumqttc::ClientError> {
    let status = DeviceState {
        online: true,
        device_name: device_name.into(),
        timestamp: chrono::Utc::now().timestamp(),
    };
    self.client
        .publish(
            self.topics.device_state(),
            QoS::AtLeastOnce,
            true,
            status.encode_to_vec(),
        )
        .await
}
```

- [ ] **Step 2:** In `daemon/src/mqtt/publisher.rs`, change `publish_device_state` to single-publish:
```rust
/// Publishes DeviceState (online/offline) to device/{id}/state retained.
pub async fn publish_device_state(&self, state: &amux::DeviceState) -> Result<(), rumqttc::ClientError> {
    self.client.client
        .publish(self.client.topics.device_state(), QoS::AtLeastOnce, true, state.encode_to_vec())
        .await
}
```

- [ ] **Step 3:** In `daemon/src/mqtt/topics.rs`, delete `pub fn status(&self)`. Drop `t.status()` assertion from `legacy_paths_still_work` (or delete the whole test if only that remains).

Verify no remaining `topics.status()` call:
```bash
/usr/bin/grep -rn "topics\.status\(\)\|self\.topics\.status" daemon/src
```

- [ ] **Step 4:** Test_client.rs subscribes to `topics.status()` at line 56. Patch it to subscribe to `topics.device_state()` instead — this is needed for Task 5's commit to keep the binary building. Task 6 polishes test_client further.

- [ ] **Step 5:** Build and test.
```bash
cd /Volumes/openbeta/workspace/amux/daemon && cargo test 2>&1 | tail -10
```
Expected: tests pass.

- [ ] **Step 6:** Commit.
```bash
git add daemon/src/mqtt/client.rs daemon/src/mqtt/publisher.rs daemon/src/mqtt/topics.rs daemon/src/cli/test_client.rs
git commit -m "refactor(daemon): LWT retargets to device/state; drop legacy /status topic"
```

---

### Task 6: test_client.rs cleanup + final verification

**Files:** `daemon/src/cli/test_client.rs`

- [ ] **Step 1:** Audit the `test_client.rs` file for any remaining references to retired topics or types:
```bash
/usr/bin/grep -n "agent_commands\|status\(\)\|peers\(\)\|workspaces\(\)\|collab\(\)\|DeviceCollab\|DeviceCommandEnvelope\|publish_peer_list\|publish_workspace_list" daemon/src/cli/test_client.rs
```

For each match:
- Subscribe to `topics.peers()` / `topics.workspaces()` → switch to `topics.device_notify()` (notify channel is the new "list changed" trigger), or just drop the subscribe if the test no longer needs it.
- `topics.status()` → `topics.device_state()` (already done in Task 5).
- `topics.agent_commands("new")` (lines 251, 391 if still present) → already patched in Task 4 to `topics.runtime_commands("new")`.
- Remove any unused imports of `DeviceCollab*` or other deleted types.

- [ ] **Step 2:** Run `cargo build` and `cargo test`:
```bash
cd /Volumes/openbeta/workspace/amux/daemon && cargo build 2>&1 | tail -10
cargo test 2>&1 | tail -10
```
Expected: clean build + tests pass.

- [ ] **Step 3:** Final cross-cutting verification grep — confirm zero remaining live references to retired publishers/topics in non-Phase-5-deletable code:
```bash
/usr/bin/grep -rEn "topics\.(status|peers|workspaces|collab|agent_state|agent_events|agent_commands|all_agent_commands)\(|publish_(peer_list|workspace_list|device_collab_event|device_collab_event_to)" daemon/src
```
Expected: zero matches.

- [ ] **Step 4:** Commit any test_client cleanup.
```bash
git add daemon/src/cli/test_client.rs
git commit -m "chore(daemon): test_client uses new runtime/state topics; drops retired refs"
```

(If no further changes, skip this step.)
