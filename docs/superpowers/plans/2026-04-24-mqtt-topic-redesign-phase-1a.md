# MQTT Topic Redesign — Phase 1a Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land the daemon-side dual-publish / dual-subscribe infrastructure for the MQTT topic redesign: merge `TeamclawTopics` into a single `Topics` module, add new `device/{id}/state`, `device/{id}/runtime/{id}/*`, `user/{actor}/notify` path builders, publish runtime state/events on both old (`agent/{id}/*`) and new (`runtime/{id}/*`) topics in parallel, publish `DeviceState` on both `/status` and `/state` (LWT stays on `/status` per spec), subscribe to both command path shapes. **Zero iOS changes.** Old iOS keeps working on legacy topics; new iOS (Phase 2) will switch to new paths. All 9 new RPC method variants from Phase 0 keep their `"... not yet implemented"` placeholder handlers — real implementations are Phase 1b.

**Architecture:** Daemon code only. Two-sided expansion: every existing publish on `agent/{id}/state` / `agent/{id}/events` / `device/{id}/status` gets a parallel publish on the new topic path in the same publisher call. Every existing subscription on `agent/+/commands` + `collab` also subscribes to `runtime/+/commands`. LWT wiring is unchanged — broker still fires the will on `device/{id}/status` on crash, which is correct for the compat window. No new handlers, no new state transitions — just parallel publishing and parallel subscription. The single `Topics` struct exposes both legacy and new path helpers so publisher/subscriber code can address either wire shape.

**Tech Stack:** Rust (prost, rumqttc), no new dependencies. Changes are confined to `daemon/src/mqtt/` and `daemon/src/teamclaw/`.

**Reference:** `docs/superpowers/specs/2026-04-24-mqtt-topic-redesign-design.md` — "Migration Plan → Phase 1". Spec wins over plan where they differ; stop and update the plan if a conflict surfaces.

**Out of scope for Phase 1a:**
- Real RPC handlers for the Phase 0 placeholder match arms (`StartRuntime`, `StopRuntime`, `AnnouncePeer`, `DisconnectPeer`, `RemoveMember`, `AddWorkspace`, `RemoveWorkspace`, `FetchPeers`, `FetchWorkspaces`) — these stay as `"... not yet implemented"` stubs; Phase 1b replaces them.
- Runtime lifecycle state machine (STARTING → ACTIVE → FAILED/STOPPED publishing with stage transitions) — Phase 1b. Phase 1a only sets `state = ACTIVE` on steady-state publishes of already-running runtimes; no new startup or failure publishes.
- `user/{actor}/notify` publishes + transactional outbox — Phase 1c. Both infrastructure prerequisites (Supabase `user_inbox` table, HiveMQ JWT auth) must ship first. The `Topics::user_notify()` path builder IS added in this phase but no callers use it yet.
- iOS subscription changes — all Phase 2.
- Internal Rust renames (`AgentManager` → `RuntimeManager`, `agent/` module → `runtime/`) — Phase 4.
- Legacy proto deletion — Phase 5.

---

## File Structure

**Rust files edited:**
- `daemon/src/mqtt/topics.rs` — absorb `TeamclawTopics` methods + add new `device_state`, `runtime_*`, `user_notify` path builders
- `daemon/src/teamclaw/topics.rs` — **deleted**
- `daemon/src/teamclaw/mod.rs` — remove `TeamclawTopics` re-export
- `daemon/src/teamclaw/live.rs` — use `Topics` instead of `TeamclawTopics`
- `daemon/src/teamclaw/notify.rs` — use `Topics` instead of `TeamclawTopics`
- `daemon/src/teamclaw/session_manager.rs` — use `Topics` instead of `TeamclawTopics`
- `daemon/src/mqtt/publisher.rs` — add parallel publish calls for runtime state, runtime events, device state; extend retained cleanup to both paths
- `daemon/src/daemon/server.rs` — no code change expected (it calls publisher methods that now fan out internally) EXCEPT at the subscriber dispatch to recognize the new `RuntimeCommand` variant
- `daemon/src/agent/handle.rs` — set `RuntimeInfo.state = RuntimeLifecycle::Active as i32` in `to_proto_info()`
- `daemon/src/config/session_store.rs` — set `RuntimeInfo.state = RuntimeLifecycle::Active as i32` in the matching construction site
- `daemon/src/mqtt/subscriber.rs` — recognize `runtime/+/commands` topic, emit new `IncomingMessage::RuntimeCommand` variant
- `daemon/src/mqtt/client.rs` — subscribe to `runtime/+/commands` wildcard alongside existing `agent/+/commands` in `subscribe_all()`

**Tests added:**
- `daemon/src/mqtt/topics.rs` — unit tests for new path builders (stringified-path assertions)
- `daemon/src/mqtt/subscriber.rs` — parse tests for `runtime/+/commands` paths

**Behavior at end of Phase 1a:**
- Daemon publishes runtime state on BOTH `device/{id}/agent/{id}/state` AND `device/{id}/runtime/{id}/state`
- Daemon publishes runtime events on BOTH paths
- Daemon publishes `DeviceState` on BOTH `device/{id}/status` AND `device/{id}/state`; LWT remains on `/status`
- Daemon accepts `RuntimeCommandEnvelope` on `device/{id}/runtime/+/commands` AND `CommandEnvelope` on `device/{id}/agent/+/commands` (both dispatch through the same ACP handler)
- Retained `device/{id}/peers` and `device/{id}/workspaces` still published (iOS still reads them; RPC replacements land Phase 1b)
- `user/{actor}/notify` is NOT published yet (prereqs not met)
- 9 placeholder RPC match arms in `session_manager.rs` still return `"... not yet implemented"` (Phase 1b)

---

## Task 1: Verify green baseline

**Files:** none (verification only)

- [ ] **Step 1: Confirm daemon builds + tests pass**

Run:
```bash
cd /Volumes/openbeta/workspace/amux/daemon && set -a && source .env && set +a && cargo build 2>&1 | tail -3 && cargo test --no-fail-fast 2>&1 | tail -3
```
Expected: `Finished \`dev\` profile`; `cargo test: 92 passed`. If not green, stop and triage before proceeding.

- [ ] **Step 2: Confirm iOS builds**

```bash
cd /Volumes/openbeta/workspace/amux/ios && xcodebuild -project AMUX.xcodeproj -scheme AMUX -destination 'generic/platform=iOS' -configuration Debug build CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "BUILD SUCCEEDED|BUILD FAILED" | head -2
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Confirm HEAD is at Phase 0 final**

```bash
cd /Volumes/openbeta/workspace/amux && git log --oneline -1
```
Expected: `8482f4ce feat(proto): add Notify message for device and user invalidation` (or a later commit that still has Phase 0 complete).

No commit in this task.

---

## Task 2: Consolidate `TeamclawTopics` into `Topics`

**Files:**
- Modify: `daemon/src/mqtt/topics.rs`
- Delete: `daemon/src/teamclaw/topics.rs`
- Modify: `daemon/src/teamclaw/mod.rs`
- Modify: `daemon/src/teamclaw/live.rs`
- Modify: `daemon/src/teamclaw/notify.rs`
- Modify: `daemon/src/teamclaw/session_manager.rs`

Move the four `TeamclawTopics` methods (`device_rpc_req`, `device_rpc_res`, `device_notify`, `session_live`) into `Topics`. Delete the `TeamclawTopics` struct. Update all four consumers to use `Topics::new(...)` instead.

- [ ] **Step 1: Add the 4 methods to `Topics`**

In `daemon/src/mqtt/topics.rs`, append to the `impl Topics { ... }` block (after `all_agent_commands`):

```rust
    // ─── Teamclaw (absorbed from teamclaw/topics.rs in Phase 1a) ───

    pub fn device_rpc_req(&self) -> String {
        format!("{}/rpc/req", self.device_base())
    }

    pub fn device_rpc_res(&self) -> String {
        format!("{}/rpc/res", self.device_base())
    }

    pub fn device_notify(&self) -> String {
        format!("{}/notify", self.device_base())
    }

    pub fn session_live(&self, session_id: &str) -> String {
        format!("amux/{}/session/{}/live", self.team_id, session_id)
    }
```

- [ ] **Step 2: Add unit tests for the absorbed methods**

In `daemon/src/mqtt/topics.rs`, append at end of file:

```rust
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn absorbed_rpc_paths() {
        let t = Topics::new("team1", "dev-a");
        assert_eq!(t.device_rpc_req(), "amux/team1/device/dev-a/rpc/req");
        assert_eq!(t.device_rpc_res(), "amux/team1/device/dev-a/rpc/res");
    }

    #[test]
    fn absorbed_notify_and_session_live() {
        let t = Topics::new("team1", "dev-a");
        assert_eq!(t.device_notify(), "amux/team1/device/dev-a/notify");
        assert_eq!(t.session_live("s1"), "amux/team1/session/s1/live");
    }
}
```

- [ ] **Step 3: Run the new tests to confirm they pass**

```bash
cd /Volumes/openbeta/workspace/amux/daemon && set -a && source .env && set +a && cargo test -p amuxd mqtt::topics 2>&1 | tail -5
```
Expected: `test result: ok. 2 passed`.

- [ ] **Step 4: Delete `daemon/src/teamclaw/topics.rs`**

```bash
rm /Volumes/openbeta/workspace/amux/daemon/src/teamclaw/topics.rs
```

- [ ] **Step 5: Remove `TeamclawTopics` export from `daemon/src/teamclaw/mod.rs`**

Find and delete these lines in `daemon/src/teamclaw/mod.rs`:

```rust
pub use topics::TeamclawTopics;
```

And the `mod topics;` / `pub mod topics;` declaration (whichever form the file uses).

- [ ] **Step 6: Update `daemon/src/teamclaw/live.rs`**

Replace:
```rust
use crate::teamclaw::TeamclawTopics;
```
with:
```rust
use crate::mqtt::topics::Topics;
```

Replace the struct field type:
```rust
topics: TeamclawTopics,
```
with:
```rust
topics: Topics,
```

Replace the constructor call:
```rust
topics: TeamclawTopics::new(&team_id, &device_id),
```
with:
```rust
topics: Topics::new(&team_id, &device_id),
```

- [ ] **Step 7: Update `daemon/src/teamclaw/notify.rs`**

Replace:
```rust
use crate::teamclaw::TeamclawTopics;
```
with:
```rust
use crate::mqtt::topics::Topics;
```

Replace any `TeamclawTopics::new(...)` call with `Topics::new(...)`. Same method names are used on the result (`.device_notify()`), no further changes needed.

- [ ] **Step 8: Update `daemon/src/teamclaw/session_manager.rs`**

In the `use` statement at the top:
```rust
use crate::teamclaw::{... TeamclawTopics, ...};
```
remove `TeamclawTopics` from the import list; add:
```rust
use crate::mqtt::topics::Topics;
```

Replace the struct field type `topics: TeamclawTopics` → `topics: Topics`.

Replace the constructor call:
```rust
let topics = TeamclawTopics::new(team_id, device_id);
```
with:
```rust
let topics = Topics::new(team_id, device_id);
```

- [ ] **Step 9: Verify compile + tests**

```bash
cd /Volumes/openbeta/workspace/amux/daemon && set -a && source .env && set +a && cargo build 2>&1 | tail -3 && cargo test --no-fail-fast 2>&1 | tail -3
```
Expected: clean build; 94 tests pass (92 baseline + 2 new topic tests).

- [ ] **Step 10: Commit**

```bash
cd /Volumes/openbeta/workspace/amux && git add daemon/src/mqtt/topics.rs daemon/src/teamclaw/mod.rs daemon/src/teamclaw/live.rs daemon/src/teamclaw/notify.rs daemon/src/teamclaw/session_manager.rs && git add -u daemon/src/teamclaw/topics.rs && git commit -m "$(cat <<'EOF'
refactor(mqtt): absorb TeamclawTopics into Topics

Four path builders (device_rpc_req, device_rpc_res, device_notify,
session_live) move from daemon/src/teamclaw/topics.rs to
daemon/src/mqtt/topics.rs. TeamclawTopics struct is deleted. Consumers
in teamclaw/live.rs, teamclaw/notify.rs, teamclaw/session_manager.rs
switch to Topics. Method names and string outputs are unchanged — pure
module-level move + 2 new unit tests.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

Verify: `git show HEAD --stat | tail -10` — expect 5 modified + 1 deleted file, no unrelated edits.

---

## Task 3: Add new `Topics` path builders

**Files:**
- Modify: `daemon/src/mqtt/topics.rs`

Add the new Phase 1a path builders: `device_state`, `runtime_state`, `runtime_events`, `runtime_commands`, `runtime_state_wildcard`, `runtime_commands_wildcard`, `user_notify`. Legacy builders (`status`, `agent_state`, `agent_events`, `agent_commands`, `all_agent_commands`, `peers`, `workspaces`, `collab`, `collab_for`) stay unchanged.

- [ ] **Step 1: Add new methods to `Topics`**

In `daemon/src/mqtt/topics.rs`, append to the `impl Topics { ... }` block (after the Teamclaw methods added in Task 2):

```rust
    // ─── Phase 1 dual-write additions ───

    /// New device-scoped retained state topic. LWT migrates here in Phase 3.
    pub fn device_state(&self) -> String {
        format!("{}/state", self.device_base())
    }

    /// Per-runtime retained state. iOS subscribes via runtime_state_wildcard.
    pub fn runtime_state(&self, runtime_id: &str) -> String {
        format!("{}/runtime/{}/state", self.device_base(), runtime_id)
    }

    /// Per-runtime event stream.
    pub fn runtime_events(&self, runtime_id: &str) -> String {
        format!("{}/runtime/{}/events", self.device_base(), runtime_id)
    }

    /// Per-runtime command stream.
    pub fn runtime_commands(&self, runtime_id: &str) -> String {
        format!("{}/runtime/{}/commands", self.device_base(), runtime_id)
    }

    /// Wildcard for aggregating all retained runtime states for this device.
    pub fn runtime_state_wildcard(&self) -> String {
        format!("{}/runtime/+/state", self.device_base())
    }

    /// Wildcard for subscribing to all incoming runtime commands for this device.
    pub fn runtime_commands_wildcard(&self) -> String {
        format!("{}/runtime/+/commands", self.device_base())
    }

    /// Team-scoped user notify channel. Requires broker JWT auth before use
    /// (Phase 1c prerequisite); path builder available now for Phase 2 iOS.
    pub fn user_notify(&self, actor_id: &str) -> String {
        format!("amux/{}/user/{}/notify", self.team_id, actor_id)
    }
```

- [ ] **Step 2: Add unit tests**

In the `#[cfg(test)] mod tests` block at the end of `daemon/src/mqtt/topics.rs`, append:

```rust
    #[test]
    fn new_device_state_and_runtime_paths() {
        let t = Topics::new("team1", "dev-a");
        assert_eq!(t.device_state(), "amux/team1/device/dev-a/state");
        assert_eq!(
            t.runtime_state("r1"),
            "amux/team1/device/dev-a/runtime/r1/state"
        );
        assert_eq!(
            t.runtime_events("r1"),
            "amux/team1/device/dev-a/runtime/r1/events"
        );
        assert_eq!(
            t.runtime_commands("r1"),
            "amux/team1/device/dev-a/runtime/r1/commands"
        );
        assert_eq!(
            t.runtime_state_wildcard(),
            "amux/team1/device/dev-a/runtime/+/state"
        );
        assert_eq!(
            t.runtime_commands_wildcard(),
            "amux/team1/device/dev-a/runtime/+/commands"
        );
    }

    #[test]
    fn user_notify_path() {
        let t = Topics::new("team1", "dev-a");
        assert_eq!(
            t.user_notify("actor-xyz"),
            "amux/team1/user/actor-xyz/notify"
        );
    }

    #[test]
    fn legacy_paths_still_work() {
        // Regression — the dual-write window relies on these staying
        // byte-identical to today's daemon output.
        let t = Topics::new("team1", "dev-a");
        assert_eq!(t.status(), "amux/team1/device/dev-a/status");
        assert_eq!(t.peers(), "amux/team1/device/dev-a/peers");
        assert_eq!(t.workspaces(), "amux/team1/device/dev-a/workspaces");
        assert_eq!(t.collab(), "amux/team1/device/dev-a/collab");
        assert_eq!(
            t.agent_state("a1"),
            "amux/team1/device/dev-a/agent/a1/state"
        );
        assert_eq!(
            t.agent_events("a1"),
            "amux/team1/device/dev-a/agent/a1/events"
        );
        assert_eq!(
            t.agent_commands("a1"),
            "amux/team1/device/dev-a/agent/a1/commands"
        );
        assert_eq!(
            t.all_agent_commands(),
            "amux/team1/device/dev-a/agent/+/commands"
        );
    }
```

- [ ] **Step 3: Run tests**

```bash
cd /Volumes/openbeta/workspace/amux/daemon && set -a && source .env && set +a && cargo test -p amuxd mqtt::topics 2>&1 | tail -5
```
Expected: 5 tests pass (2 from Task 2 + 3 new).

- [ ] **Step 4: Full build + test**

```bash
cd /Volumes/openbeta/workspace/amux/daemon && set -a && source .env && set +a && cargo build 2>&1 | tail -3 && cargo test --no-fail-fast 2>&1 | tail -3
```
Expected: clean build; 97 tests pass (94 + 3 new).

- [ ] **Step 5: Commit**

```bash
cd /Volumes/openbeta/workspace/amux && git add daemon/src/mqtt/topics.rs && git commit -m "$(cat <<'EOF'
feat(mqtt): add Phase 1 Topics path builders (device_state, runtime_*, user_notify)

Phase 1 dual-publish requires new path strings alongside the legacy ones.
All legacy builders (status, agent_state, agent_events, agent_commands,
peers, workspaces, collab, collab_for) stay untouched — dual-publish keeps
writing to them until Phase 3. Adds regression tests pinning the legacy
paths to their current byte-exact strings.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Publisher — dual-publish runtime state, populate `state = ACTIVE`

**Files:**
- Modify: `daemon/src/mqtt/publisher.rs`
- Modify: `daemon/src/agent/handle.rs`
- Modify: `daemon/src/config/session_store.rs`

Every call to `publish_agent_state` must now also publish the same `RuntimeInfo` to `runtime/{id}/state`. Also: populate `RuntimeInfo.state = RuntimeLifecycle::Active as i32` at the construction sites — without this, new iOS clients will see `UNKNOWN` on steady-state publishes. Full lifecycle transitions (STARTING, FAILED, STOPPED) land in Phase 1b.

- [ ] **Step 1: Extend `publish_agent_state` in `daemon/src/mqtt/publisher.rs` to also publish to the new path**

Locate the current `publish_agent_state` method:

```rust
    pub async fn publish_agent_state(&self, agent_id: &str, info: &amux::RuntimeInfo) -> Result<(), rumqttc::ClientError> {
        self.client.client
            .publish(self.client.topics.agent_state(agent_id), QoS::AtLeastOnce, true, info.encode_to_vec())
            .await
    }
```

Replace with:

```rust
    /// Dual-publishes RuntimeInfo to BOTH the legacy agent/{id}/state and
    /// the new runtime/{id}/state retained topics during the Phase 1-2
    /// compat window. Phase 3 drops the legacy publish.
    pub async fn publish_agent_state(&self, agent_id: &str, info: &amux::RuntimeInfo) -> Result<(), rumqttc::ClientError> {
        let payload = info.encode_to_vec();
        self.client.client
            .publish(self.client.topics.agent_state(agent_id), QoS::AtLeastOnce, true, payload.clone())
            .await?;
        self.client.client
            .publish(self.client.topics.runtime_state(agent_id), QoS::AtLeastOnce, true, payload)
            .await
    }
```

Method name stays `publish_agent_state` for now — renaming to `publish_runtime_state` is a Phase 4 concern. What changed is the implementation publishes to both wire paths.

- [ ] **Step 2: Extend `clear_agent_state` to clear BOTH retain paths**

Locate `clear_agent_state`:

```rust
    pub async fn clear_agent_state(&self, agent_id: &str) -> Result<(), rumqttc::ClientError> {
        self.client.client
            .publish(self.client.topics.agent_state(agent_id), QoS::AtLeastOnce, true, Vec::<u8>::new())
            .await
    }
```

Replace with:

```rust
    /// Clears retained state on BOTH the legacy agent/{id}/state and the
    /// new runtime/{id}/state paths. Otherwise a legacy subscriber or a
    /// new subscriber would see ghost state after runtime termination.
    pub async fn clear_agent_state(&self, agent_id: &str) -> Result<(), rumqttc::ClientError> {
        self.client.client
            .publish(self.client.topics.agent_state(agent_id), QoS::AtLeastOnce, true, Vec::<u8>::new())
            .await?;
        self.client.client
            .publish(self.client.topics.runtime_state(agent_id), QoS::AtLeastOnce, true, Vec::<u8>::new())
            .await
    }
```

- [ ] **Step 3: Populate `RuntimeInfo.state = ACTIVE` in `daemon/src/agent/handle.rs`**

Read the current `to_proto_info` implementation (~line 63 of `daemon/src/agent/handle.rs`). Find the `amux::RuntimeInfo { ... }` literal. Change the line:

```rust
            state: amux::RuntimeLifecycle::Unknown as i32,
```

(or whatever default was set in Phase 0 Task 3) to:

```rust
            state: amux::RuntimeLifecycle::Active as i32,
```

`AgentHandle::to_proto_info()` is only called when the subprocess is up (the adapter wouldn't hand back a handle otherwise), so hardcoding `ACTIVE` here is the simplest honest mapping. STARTING/FAILED/STOPPED get published by the Phase 1b lifecycle machine.

- [ ] **Step 4: Populate `state = ACTIVE` in `daemon/src/config/session_store.rs`**

Find the second `RuntimeInfo { ... }` literal (from Phase 0 Task 3). Apply the same one-line change:

```rust
            state: amux::RuntimeLifecycle::Unknown as i32,
```
→
```rust
            state: amux::RuntimeLifecycle::Active as i32,
```

(If the construction site represents a runtime that might NOT actually be running — e.g. reading back a stale stored session on daemon startup — re-check with a comment: `// Stored sessions represent runtimes the daemon will re-spawn; ACTIVE is correct iff spawn succeeds. Phase 1b will wire proper state transitions.` Add that comment inline if it clarifies intent.)

- [ ] **Step 5: Compile + test**

```bash
cd /Volumes/openbeta/workspace/amux/daemon && set -a && source .env && set +a && cargo build 2>&1 | tail -3 && cargo test --no-fail-fast 2>&1 | tail -3
```
Expected: clean build; 97 tests pass (no new tests in this task; existing coverage verifies encode/decode of RuntimeInfo with state populated).

- [ ] **Step 6: Commit**

```bash
cd /Volumes/openbeta/workspace/amux && git add daemon/src/mqtt/publisher.rs daemon/src/agent/handle.rs daemon/src/config/session_store.rs && git commit -m "$(cat <<'EOF'
feat(mqtt): dual-publish runtime state on agent/{id}/state and runtime/{id}/state

publish_agent_state and clear_agent_state now write to BOTH the legacy
and Phase 1+ retained state topics in every call. Byte-identical
RuntimeInfo payload on both paths. Populates RuntimeInfo.state = ACTIVE
at construction since the existing publish paths only fire for running
runtimes; startup/failure transitions are Phase 1b.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Publisher — dual-publish runtime events

**Files:**
- Modify: `daemon/src/mqtt/publisher.rs`

Same pattern as Task 4, but for the ephemeral `events` topic. QoS 1, `retain: false`.

- [ ] **Step 1: Extend `publish_agent_event` to dual-publish**

Locate in `daemon/src/mqtt/publisher.rs`:

```rust
    pub async fn publish_agent_event(&self, agent_id: &str, envelope: &amux::Envelope) -> Result<(), rumqttc::ClientError> {
        self.client.client
            .publish(self.client.topics.agent_events(agent_id), QoS::AtLeastOnce, false, envelope.encode_to_vec())
            .await
    }
```

Replace with:

```rust
    /// Dual-publishes Envelope to BOTH agent/{id}/events (legacy) and
    /// runtime/{id}/events during the Phase 1-2 compat window. Ephemeral;
    /// no retain.
    pub async fn publish_agent_event(&self, agent_id: &str, envelope: &amux::Envelope) -> Result<(), rumqttc::ClientError> {
        let payload = envelope.encode_to_vec();
        self.client.client
            .publish(self.client.topics.agent_events(agent_id), QoS::AtLeastOnce, false, payload.clone())
            .await?;
        self.client.client
            .publish(self.client.topics.runtime_events(agent_id), QoS::AtLeastOnce, false, payload)
            .await
    }
```

- [ ] **Step 2: Compile + test**

```bash
cd /Volumes/openbeta/workspace/amux/daemon && set -a && source .env && set +a && cargo build 2>&1 | tail -3 && cargo test --no-fail-fast 2>&1 | tail -3
```
Expected: clean; 97 tests pass.

- [ ] **Step 3: Commit**

```bash
cd /Volumes/openbeta/workspace/amux && git add daemon/src/mqtt/publisher.rs && git commit -m "$(cat <<'EOF'
feat(mqtt): dual-publish runtime events on agent/{id}/events and runtime/{id}/events

Every envelope now goes out on both topic shapes during the compat window.
Ephemeral — no retain on either path.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Publisher — dual-publish device state (LWT stays on `/status`)

**Files:**
- Modify: `daemon/src/mqtt/publisher.rs`
- Modify: `daemon/src/daemon/server.rs` (if it directly publishes DeviceState/DeviceStatus)
- Modify: `daemon/src/mqtt/client.rs` (only to verify LWT target — do NOT change it)

MQTT allows exactly one LWT per connection. Per spec "Phase 1": LWT stays on `device/{id}/status` through Phase 2, moves to `device/{id}/state` in Phase 3. Phase 1a publishes `DeviceState` on BOTH retained topics for every normal (non-LWT) transition — startup online, graceful shutdown offline, reconnect online. The LWT on `/status` remains unchanged.

- [ ] **Step 1: Find current DeviceState publish sites**

```bash
cd /Volumes/openbeta/workspace/amux && grep -rn "DeviceState\b\|topics\.status\b" daemon/src --include='*.rs' | grep -v "^Binary"
```
Map the hits: the LWT construction in `mqtt/client.rs`, plus any `publish` calls on `topics.status()` in `server.rs` or elsewhere.

- [ ] **Step 2: Add `publish_device_state` helper to Publisher**

In `daemon/src/mqtt/publisher.rs`, add a new public method:

```rust
    /// Publishes DeviceState (online/offline) to BOTH legacy /status and
    /// new /state retained topics. Used for normal online/offline
    /// transitions. LWT (crash path) still fires only on /status until
    /// Phase 3 retargets it.
    pub async fn publish_device_state(&self, state: &amux::DeviceState) -> Result<(), rumqttc::ClientError> {
        let payload = state.encode_to_vec();
        self.client.client
            .publish(self.client.topics.status(), QoS::AtLeastOnce, true, payload.clone())
            .await?;
        self.client.client
            .publish(self.client.topics.device_state(), QoS::AtLeastOnce, true, payload)
            .await
    }
```

- [ ] **Step 3: Route current DeviceState publishes through the new helper**

For every `self.client.client.publish(self.client.topics.status(), ...)` call that encodes a `DeviceState` payload (manually-published online/offline, NOT the LWT config), replace with a call to `publisher.publish_device_state(&state).await`.

If there is a `Publisher` helper already used at those sites, add the new method call there. If not, construct `Publisher::new(&mqtt_client)` and call it.

Likely call sites (from prior greps): `daemon/src/daemon/server.rs` around startup / reconnect logic — search for `announce_online`, `publish DeviceState`, `topics.status()`.

- [ ] **Step 4: DO NOT change the LWT in `mqtt/client.rs`**

Open `daemon/src/mqtt/client.rs` and confirm the LWT block (around line 87-99) still reads:

```rust
        let lwt = rumqttc::LastWill::new(
            topics.status(),
            lwt_payload.encode_to_vec(),
            QoS::AtLeastOnce,
            true,
        );
        opts.set_last_will(lwt);
```

Add a comment above the LWT block:

```rust
        // Phase 1a: LWT stays on device/{id}/status. /state is dual-published
        // for normal transitions but NOT LWT-backed in Phase 1-2. Phase 3
        // retargets LWT to /state when /status is retired.
```

Do NOT change the LWT target itself.

- [ ] **Step 5: Compile + test**

```bash
cd /Volumes/openbeta/workspace/amux/daemon && set -a && source .env && set +a && cargo build 2>&1 | tail -3 && cargo test --no-fail-fast 2>&1 | tail -3
```
Expected: clean; 97 tests pass.

- [ ] **Step 6: Commit**

```bash
cd /Volumes/openbeta/workspace/amux && git add daemon/src/mqtt/publisher.rs daemon/src/mqtt/client.rs daemon/src/daemon/server.rs && git commit -m "$(cat <<'EOF'
feat(mqtt): dual-publish DeviceState on /status and /state (LWT stays on /status)

Normal online/offline transitions write to both retained topics so the
Phase 2 iOS client can read /state and merge with /status via offline-wins.
LWT continues firing on /status until Phase 3 — the broker supports only
one Will per connection. Document the LWT stability at the client.rs
construction site.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: Subscriber — recognize `runtime/+/commands` + dual-subscribe

**Files:**
- Modify: `daemon/src/mqtt/subscriber.rs`
- Modify: `daemon/src/mqtt/client.rs` (subscribe to the new wildcard in `subscribe_all`)
- Modify: `daemon/src/daemon/server.rs` (add dispatch arm for the new variant)

The daemon must accept commands on BOTH `device/{id}/agent/+/commands` (legacy, `CommandEnvelope` payload) and `device/{id}/runtime/+/commands` (new, `RuntimeCommandEnvelope` payload) during the compat window. Both carry the same `AcpCommand` oneof so dispatch is identical after decode.

- [ ] **Step 1: Add new `IncomingMessage` variant for runtime commands**

In `daemon/src/mqtt/subscriber.rs`, extend the `IncomingMessage` enum:

```rust
pub enum IncomingMessage {
    AgentCommand {
        agent_id: String,
        envelope: amux::CommandEnvelope,
    },
    // New Phase 1a variant: decoded from device/{id}/runtime/+/commands
    // Structurally carries the same AcpCommand oneof as AgentCommand; the
    // dispatcher unifies them.
    RuntimeCommand {
        runtime_id: String,
        envelope: amux::RuntimeCommandEnvelope,
    },
    DeviceCollab {
        envelope: amux::DeviceCommandEnvelope,
    },
    TeamclawRpc {
        topic: String,
        payload: Vec<u8>,
    },
    TeamclawNotify {
        device_id: String,
        payload: Vec<u8>,
    },
    TeamclawSessionLive {
        session_id: String,
        payload: Vec<u8>,
    },
}
```

- [ ] **Step 2: Extend `parse_incoming` to recognize the new topic shape**

In the same file, find the block starting with `if topic.contains("/agent/") && topic.ends_with("/commands") { ... }`. Immediately before it, add a parallel block:

```rust
    if topic.contains("/runtime/") && topic.ends_with("/commands") {
        let parts: Vec<&str> = topic.split('/').collect();
        // amux / {team} / device / {device_id} / runtime / {runtime_id} / commands
        // = 7 segments
        if parts.len() == 7 && parts[4] == "runtime" {
            let runtime_id = parts[5].to_string();
            match amux::RuntimeCommandEnvelope::decode(publish.payload.as_ref()) {
                Ok(envelope) => {
                    return Some(IncomingMessage::RuntimeCommand {
                        runtime_id,
                        envelope,
                    });
                }
                Err(e) => warn!("failed to decode RuntimeCommandEnvelope: {}", e),
            }
        }
    }
```

Keep the existing `/agent/` block intact — both must work in the compat window.

- [ ] **Step 3: Add parse tests for the new variant**

In `daemon/src/mqtt/subscriber.rs`, append (or extend existing test module):

```rust
#[cfg(test)]
mod tests {
    use super::*;
    use prost::Message as ProstMessage;
    use rumqttc::Publish;

    #[test]
    fn parse_legacy_agent_commands_still_works() {
        let envelope = amux::CommandEnvelope {
            runtime_id: "rt1".to_string(),
            device_id: "dev-a".to_string(),
            ..Default::default()
        };
        let p = Publish::new(
            "amux/team1/device/dev-a/agent/rt1/commands",
            rumqttc::QoS::AtLeastOnce,
            envelope.encode_to_vec(),
        );
        let msg = parse_incoming(&p).expect("should parse");
        match msg {
            IncomingMessage::AgentCommand { agent_id, .. } => {
                assert_eq!(agent_id, "rt1");
            }
            _ => panic!("wrong variant"),
        }
    }

    #[test]
    fn parse_runtime_commands_routes_to_new_variant() {
        let envelope = amux::RuntimeCommandEnvelope {
            runtime_id: "rt1".to_string(),
            device_id: "dev-a".to_string(),
            ..Default::default()
        };
        let p = Publish::new(
            "amux/team1/device/dev-a/runtime/rt1/commands",
            rumqttc::QoS::AtLeastOnce,
            envelope.encode_to_vec(),
        );
        let msg = parse_incoming(&p).expect("should parse");
        match msg {
            IncomingMessage::RuntimeCommand { runtime_id, .. } => {
                assert_eq!(runtime_id, "rt1");
            }
            _ => panic!("wrong variant"),
        }
    }
}
```

- [ ] **Step 4: Run new tests to confirm pass**

```bash
cd /Volumes/openbeta/workspace/amux/daemon && set -a && source .env && set +a && cargo test -p amuxd mqtt::subscriber 2>&1 | tail -5
```
Expected: `test result: ok. 2 passed`.

- [ ] **Step 5: Add `runtime/+/commands` wildcard subscription**

Find the `subscribe_all` (or similarly-named) method in `daemon/src/mqtt/client.rs` that subscribes to `self.topics.all_agent_commands()`. Immediately after that subscription, add:

```rust
        self.client
            .subscribe(self.topics.runtime_commands_wildcard(), QoS::AtLeastOnce)
            .await?;
```

- [ ] **Step 6: Dispatch the new variant in `daemon/src/daemon/server.rs`**

Find the `handle_incoming` method (~line 519) with the match on `IncomingMessage`. Add a new arm, immediately after `AgentCommand`:

```rust
            subscriber::IncomingMessage::RuntimeCommand { runtime_id, envelope } => {
                // During Phase 1-2, runtime_id on the new path is the same
                // 8-char UUID used on the legacy path. Route into the same
                // ACP handler as AgentCommand by translating the envelope.
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
                self.handle_agent_command(runtime_id, legacy_envelope).await;
            }
```

(If the existing `AgentCommand` arm calls a method other than `handle_agent_command`, mirror that method name instead.)

The translation is a structural copy because `CommandEnvelope` and `RuntimeCommandEnvelope` have the same fields — the ONLY reason both types exist is to carry the right `runtime_id` field name on each wire path. Inside the daemon, a single handler path is correct.

- [ ] **Step 7: Compile + test**

```bash
cd /Volumes/openbeta/workspace/amux/daemon && set -a && source .env && set +a && cargo build 2>&1 | tail -3 && cargo test --no-fail-fast 2>&1 | tail -3
```
Expected: clean; 99 tests pass (97 + 2 new subscriber tests).

- [ ] **Step 8: Commit**

```bash
cd /Volumes/openbeta/workspace/amux && git add daemon/src/mqtt/subscriber.rs daemon/src/mqtt/client.rs daemon/src/daemon/server.rs && git commit -m "$(cat <<'EOF'
feat(mqtt): dual-subscribe agent/+/commands and runtime/+/commands

New IncomingMessage::RuntimeCommand variant parses RuntimeCommandEnvelope
from device/{id}/runtime/+/commands. Dispatch reuses the existing
AgentCommand handler via a structural-copy translation — both envelope
types carry the same AcpCommand oneof, only the wire field name differs.
subscribe_all() subscribes to both wildcards during the compat window.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: Final verification

**Files:** none (verification only)

- [ ] **Step 1: Full clean daemon build**

```bash
cd /Volumes/openbeta/workspace/amux/daemon && cargo clean 2>&1 | tail -2
cd /Volumes/openbeta/workspace/amux/daemon && set -a && source .env && set +a && cargo build 2>&1 | tail -3
```
Expected: `Finished \`dev\` profile`, 0 errors.

- [ ] **Step 2: Full daemon tests**

```bash
cd /Volumes/openbeta/workspace/amux/daemon && set -a && source .env && set +a && cargo test --no-fail-fast 2>&1 | tail -3
```
Expected: 99 tests pass (92 baseline + 7 added in Phase 1a: 5 topics tests + 2 subscriber tests).

- [ ] **Step 3: iOS clean build**

```bash
cd /Volumes/openbeta/workspace/amux/ios && xcodebuild -project AMUX.xcodeproj -scheme AMUX -destination 'generic/platform=iOS' -configuration Debug clean build CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "BUILD SUCCEEDED|BUILD FAILED" | head -2
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Brief daemon smoke test — verify it connects and publishes on both paths**

This step verifies the actual wire behavior. It requires the daemon to connect to the configured MQTT broker and publish a heartbeat.

```bash
cd /Volumes/openbeta/workspace/amux/daemon && set -a && source .env && set +a && timeout 15s cargo run -- start 2>&1 | grep -iE "publish|subscribe|connected|online|error" | head -30
```

Expected output to include (among other log lines):
- Subscription to both `agent/+/commands` AND `runtime/+/commands`
- Publish of `DeviceState { online: true, ... }` to both `/status` and `/state`
- No `prost::DecodeError`, no `EncodeError`, no panic

If the daemon errors out for a reason unrelated to the changes (e.g. Supabase auth failure, pairing state missing), note it but don't count it as a Phase 1a regression. The key is that the MQTT paths fire correctly.

- [ ] **Step 5: Grep invariants — Phase 1a completion check**

```bash
cd /Volumes/openbeta/workspace/amux
# TeamclawTopics fully deleted from non-deleted code
grep -rn "TeamclawTopics\b" daemon/src 2>/dev/null | head -5
# Expect: zero matches

# New Topics methods referenced by the daemon
grep -rn "runtime_state\|runtime_events\|runtime_commands\|runtime_commands_wildcard\|device_state()\|user_notify(" daemon/src 2>/dev/null | head -10
# Expect: multiple hits in publisher.rs, client.rs, topics.rs

# Legacy publish paths still being called
grep -rn "topics\.agent_state\|topics\.agent_events\|topics\.status()\|all_agent_commands" daemon/src 2>/dev/null | head -10
# Expect: multiple hits — legacy path builders still used during compat

# LWT still on /status
grep -n "LastWill::new" daemon/src/mqtt/client.rs
# Verify the string argument resolves to topics.status() not device_state()
```

- [ ] **Step 6: Review commit sequence**

```bash
cd /Volumes/openbeta/workspace/amux && git log --oneline 8482f4ce..HEAD
```
Expected: ~6-7 commits, all `feat(mqtt):` or `refactor(mqtt):`. No behavioral change outside MQTT layer.

- [ ] **Step 7: Confirm no uncommitted changes**

```bash
cd /Volumes/openbeta/workspace/amux && git status --porcelain
```
Expected: only pre-existing user state (mac/Packages unresolved conflict markers, untracked ios/AMUXUITests/ + scripts/run-ios.sh). No new unrelated edits.

---

## Phase 1a Complete

At this point:
- Daemon publishes `RuntimeInfo` on BOTH `agent/{id}/state` AND `runtime/{id}/state` (retained)
- Daemon publishes events on BOTH `agent/{id}/events` AND `runtime/{id}/events`
- Daemon publishes `DeviceState` on BOTH `/status` AND `/state`; LWT unchanged
- Runtime terminations clear retains on BOTH paths
- Daemon accepts commands on BOTH `agent/+/commands` AND `runtime/+/commands`, dispatches through unified handler
- `RuntimeInfo.state = ACTIVE` is populated on every steady-state publish
- All 7 new path builders (`device_state`, `runtime_state`, `runtime_events`, `runtime_commands`, `runtime_state_wildcard`, `runtime_commands_wildcard`, `user_notify`) live in unified `Topics`; `TeamclawTopics` is deleted
- 99 daemon tests pass (92 baseline + 7 added)
- iOS build still green — zero iOS changes
- Pre-existing placeholder RPC match arms still return `"... not yet implemented"` — Phase 1b replaces them with real handlers

**Next plan (Phase 1b):** replace the 9 Phase 0 placeholder `Method::*` arms in `session_manager.rs` with real handlers. Includes the full runtime lifecycle state machine (STARTING/FAILED/STOPPED transitions, stage, error fields) so `StartRuntime` publishes state updates through the retained topic as the spawn progresses.

**Phase 1c (gated):** `user/{actor}/notify` publish via transactional outbox — only after Supabase `user_inbox` table exists and HiveMQ JWT auth migration ships.
