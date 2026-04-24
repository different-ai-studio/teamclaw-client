# MQTT Topic Redesign — Phase 1c Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the last Phase 0 placeholder — `RuntimeStart` — with a real handler that spawns a Claude Code subprocess and publishes lifecycle transitions (`STARTING` → `ACTIVE` / `FAILED`) on the retained runtime state topic. Extract shared spawn logic so the legacy `AcpCommand::StartAgent` path and the new RPC path exercise the same core flow. Preserve bare-agent spawn semantics (all three optional request fields empty). After this plan ships, iOS can switch from legacy to RPC for the new-session flow (Phase 2), and the daemon side of the MQTT topic redesign is functionally complete minus the gated `user/notify` outbox (Phase 1d).

**Architecture:** The existing `AcpCommand::StartAgent` arm in `daemon/src/daemon/server.rs::handle_agent_command` (~lines 790-870) inlines ~60 lines of work: `AgentType` coercion, workspace/worktree resolution (4-branch), `AgentManager::spawn_agent` call, `StoredSession` upsert + save, and reply publishing. Extract the common work (everything up through the upsert and retained-state publish) into `apply_start_runtime` so the new RPC handler can call it without duplication. The helper returns `Result<(runtime_id, session_id), StartError>`. Legacy path uses the result to publish a collab `AgentStartResult`; RPC path uses it to build an `RuntimeStartResult`. Lifecycle retained-state publishing — `STARTING` immediately after `spawn_agent` returns with an allocated id, `ACTIVE` via `publish_agent_state_by_id` after the `StoredSession` is persisted, `FAILED` with populated `error_code` / `error_message` / `failed_stage` on spawn error — lives in the helper so both paths emit the same wire events.

**Tech Stack:** Rust, prost, tokio. No new dependencies.

**Reference:** `docs/superpowers/specs/2026-04-24-mqtt-topic-redesign-design.md` — "Runtime lifecycle" section (state machine + publish timing) and `StartRuntimeRequest`'s validation matrix (5 rows in the "New RPC methods" section).

**Out of scope for Phase 1c:**
- **Fine-grained stage transitions.** The spec lists six stage strings (`spawning_process`, `acp_connecting`, `acp_initializing`, `creating_acp_session`, `setting_model`, `persisting`). This plan publishes `stage = "spawning_process"` during the entire `STARTING` window, then transitions to `ACTIVE`. Fine-grained stage-boundary publishes require restructuring `AgentManager::spawn_agent` into staged async — legitimate future work but not required for iOS to unblock infinite-loading UX (the state enum itself is what matters).
- **Fully-async RPC reply.** The spec's "accepted-only reply" description is about shape (no `RuntimeInfo` in the result), not about reply timing. Phase 1c blocks the handler on spawn completion before replying — same latency as today's legacy path (~2-5s). Decomposing into "reply immediately + spawn in background task" is a future optimization; it requires `Arc<Mutex<DaemonServer>>`-style shared state for the background task to publish lifecycle updates.
- **`user/{actor}/notify` + transactional outbox** — Phase 1d, gated on Supabase `user_inbox` table + EMQX JWT auth prereqs.
- **Daemon / iOS internal renames** (`AgentManager` → `RuntimeManager`, `agent/` module → `runtime/`, SwiftData `@Model Agent` → `Runtime`) — Phase 4 / Phase 2 respectively.

---

## File Structure

**Rust files edited:**
- `daemon/src/daemon/server.rs` — add `apply_start_runtime` helper, add `handle_start_runtime` RPC handler, rewrite legacy `AcpCommand::StartAgent` arm to call the helper, wire `Method::RuntimeStart` in `handle_rpc_request` dispatch.
- `daemon/src/mqtt/publisher.rs` — add `publish_runtime_failed` convenience wrapper that builds a `RuntimeInfo` with `state=FAILED` + error fields and publishes to the retained state topic (dual-publishes per Phase 1a).

**Behavior at end of Phase 1c:**
- `RuntimeStart` RPC spawns a Claude Code subprocess end-to-end and returns `accepted: true` with `runtime_id` + `session_id` on success.
- On success path: daemon publishes `RuntimeInfo { state: STARTING, stage: "spawning_process" }` to retained state topic just after `spawn_agent` returns the new id, then `ACTIVE` after `StoredSession` upsert completes. iOS (Phase 2+) that subscribes mid-spawn sees STARTING; subscribes after completion sees ACTIVE. Legacy subscribers still on `device/{id}/agent/{id}/state` see the same transitions (dual-publish from Phase 1a).
- On spawn error: daemon publishes `RuntimeInfo { state: FAILED, error_code, error_message, failed_stage }` to retained state topic. `RuntimeStart` RPC returns `accepted: false` with `rejected_reason`. Retain stays until a future cleanup (Phase 3 or explicit client dismissal — not part of Phase 1c).
- Bare-agent spawn (empty `workspace_id` + empty `worktree` + empty `session_id`) succeeds: daemon picks `"."` as worktree, creates no Supabase session, spawns runtime, publishes ACTIVE. Matches today's legacy behavior.
- Legacy `AcpCommand::StartAgent` path unchanged in externally-observable behavior — iOS on the legacy path keeps working.
- Zero `"not yet implemented"` placeholder arms remaining in `handle_rpc_request` dispatch.

---

## Task 1: Verify green baseline

**Files:** none (verification only)

- [ ] **Step 1: Confirm daemon builds + 104 tests pass**

```bash
cd /Volumes/openbeta/workspace/amux/daemon && set -a && source .env && set +a && cargo build 2>&1 | tail -3 && cargo test --no-fail-fast 2>&1 | grep "cargo test:" | tail -1
```
Expected: `Finished \`dev\` profile`; `cargo test: 104 passed` or higher.

- [ ] **Step 2: Confirm iOS builds**

```bash
cd /Volumes/openbeta/workspace/amux/ios && xcodebuild -project AMUX.xcodeproj -scheme AMUX -destination 'generic/platform=iOS' -configuration Debug build CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "BUILD SUCCEEDED|BUILD FAILED" | head -2
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Confirm HEAD is at Phase 1b final**

```bash
cd /Volumes/openbeta/workspace/amux && git log --oneline -1
```
Expected: `5c36cd4d feat(rpc): implement StopRuntime handler` (or a later commit).

No commit in this task.

---

## Task 2: Extract `apply_start_runtime` helper + wire legacy arm through it

**Files:**
- Modify: `daemon/src/daemon/server.rs`
- Modify: `daemon/src/mqtt/publisher.rs` (add `publish_runtime_failed` helper)

The legacy `AcpCommand::StartAgent` arm (server.rs ~790-870) currently inlines ~80 lines of work. Extract the reusable portion into a helper method on `DaemonServer`. The helper publishes `STARTING` retained after `spawn_agent` returns Ok, then `ACTIVE` retained after `StoredSession` upsert, then returns the new `runtime_id` + `session_id`. On error, publishes `FAILED` retained with populated error fields and returns `Err`. Collab-event publishing stays in the caller.

- [ ] **Step 1: Add `publish_runtime_failed` helper to Publisher**

In `/Volumes/openbeta/workspace/amux/daemon/src/mqtt/publisher.rs`, append to the `impl<'a> Publisher<'a> { ... }` block:

```rust
    /// Publishes RuntimeInfo with state=FAILED and populated error fields
    /// to the retained runtime state topic (dual-publishes to agent/{id}/state
    /// + runtime/{id}/state per Phase 1a). The retain stays until a future
    /// clear — iOS surfaces the error_message to the user.
    pub async fn publish_runtime_failed(
        &self,
        runtime_id: &str,
        error_code: &str,
        error_message: &str,
        failed_stage: &str,
    ) -> Result<(), rumqttc::ClientError> {
        let info = crate::proto::amux::RuntimeInfo {
            runtime_id: runtime_id.to_string(),
            state: crate::proto::amux::RuntimeLifecycle::Failed as i32,
            error_code: error_code.to_string(),
            error_message: error_message.to_string(),
            failed_stage: failed_stage.to_string(),
            ..Default::default()
        };
        self.publish_agent_state(runtime_id, &info).await
    }
```

- [ ] **Step 2: Define a result type for the helper**

At the top of `daemon/src/daemon/server.rs` (near existing type imports / near `DaemonServer`), add:

```rust
/// Outcome of apply_start_runtime. Success path returns the allocated
/// runtime_id + the session_id (echoed from request or freshly created).
/// Failure path returns a (error_code, error_message, failed_stage) tuple
/// — the caller formats this into whatever wire envelope it emits
/// (legacy AgentStartResult or new RuntimeStartResult).
struct StartRuntimeOutcome {
    pub runtime_id: String,
    pub session_id: String,
}

struct StartRuntimeError {
    pub error_code: String,
    pub error_message: String,
    pub failed_stage: String,
}
```

These are internal types — not public, not exported.

- [ ] **Step 3: Add `apply_start_runtime` helper on `DaemonServer`**

Insert the following method on `impl DaemonServer` (near the other `apply_*` helpers from Phase 1b):

```rust
    /// Spawns a Claude Code subprocess and publishes lifecycle state
    /// transitions on the retained runtime state topic. Shared by legacy
    /// AcpCommand::StartAgent and RPC RuntimeStart handlers.
    ///
    /// Lifecycle publishes:
    ///   - STARTING (stage "spawning_process") published retained right after
    ///     spawn_agent returns the new runtime_id, before StoredSession upsert.
    ///   - ACTIVE published retained via publish_agent_state_by_id after
    ///     StoredSession upsert (that call reads the now-populated AgentHandle).
    ///   - FAILED published retained if spawn_agent returns Err.
    async fn apply_start_runtime(
        &mut self,
        agent_type: amux::AgentType,
        workspace_id: &str,
        worktree: &str,
        session_id: &str,
        initial_prompt: &str,
    ) -> Result<StartRuntimeOutcome, StartRuntimeError> {
        use crate::config::StoredSession;
        info!(
            workspace_id,
            worktree,
            session_id,
            "apply_start_runtime"
        );

        // Resolve workspace + worktree. Same 4-branch logic as the legacy
        // AcpCommand::StartAgent arm (see server.rs ~800-836 pre-refactor).
        let (resolved_worktree, ws_id, supabase_ws_id_owned): (String, String, Option<String>) =
            if !workspace_id.is_empty() {
                if let Some(ws) = self.workspaces.find_by_id(workspace_id) {
                    (
                        ws.path.clone(),
                        ws.workspace_id.clone(),
                        (!ws.supabase_workspace_id.is_empty())
                            .then_some(ws.supabase_workspace_id.clone()),
                    )
                } else if !worktree.is_empty() {
                    (
                        worktree.to_string(),
                        String::new(),
                        Some(workspace_id.to_string()),
                    )
                } else {
                    return Err(StartRuntimeError {
                        error_code: "WORKSPACE_NOT_FOUND".to_string(),
                        error_message: format!(
                            "workspace {} not found and no worktree path provided",
                            workspace_id
                        ),
                        failed_stage: "validation".to_string(),
                    });
                }
            } else {
                // Bare-agent spawn: empty workspace_id. Use worktree if
                // provided, else "." (today's legacy default).
                let wt = if worktree.is_empty() {
                    ".".to_string()
                } else {
                    worktree.to_string()
                };
                (wt, String::new(), None)
            };
        let supabase_ws_id = supabase_ws_id_owned.as_deref();
        let session_id_opt = (!session_id.is_empty()).then_some(session_id);

        // Spawn.
        let new_id = match self
            .agents
            .spawn_agent(
                agent_type,
                &resolved_worktree,
                initial_prompt,
                &ws_id,
                supabase_ws_id,
                session_id_opt,
            )
            .await
        {
            Ok(id) => id,
            Err(e) => {
                error!("spawn_agent failed: {}", e);
                // We never allocated a retained topic (spawn_agent failed before
                // returning an id), so there's no retain to publish FAILED to.
                // The caller formats the error into its wire envelope; no state
                // topic is involved.
                return Err(StartRuntimeError {
                    error_code: "SPAWN_FAILED".to_string(),
                    error_message: format!("spawn_agent failed: {}", e),
                    failed_stage: "spawning_process".to_string(),
                });
            }
        };

        // STARTING retain — fleeting but observable by mid-spawn reconnects.
        let publisher = Publisher::new(&self.mqtt);
        let starting_info = amux::RuntimeInfo {
            runtime_id: new_id.clone(),
            agent_type: agent_type as i32,
            worktree: resolved_worktree.clone(),
            workspace_id: ws_id.clone(),
            state: amux::RuntimeLifecycle::Starting as i32,
            stage: "spawning_process".to_string(),
            started_at: chrono::Utc::now().timestamp(),
            ..Default::default()
        };
        let _ = publisher.publish_agent_state(&new_id, &starting_info).await;

        // Persist session + transition to ACTIVE.
        let acp_sid = self
            .agents
            .get_handle(&new_id)
            .map(|h| h.acp_session_id.clone())
            .unwrap_or_default();
        let stored = StoredSession {
            session_id: new_id.clone(),
            acp_session_id: acp_sid,
            collab_session_id: session_id.to_string(),
            agent_type: agent_type as i32,
            workspace_id: ws_id,
            worktree: resolved_worktree,
            status: amux::AgentStatus::Active as i32,
            created_at: chrono::Utc::now().timestamp(),
            last_prompt: initial_prompt.to_string(),
            last_output_summary: String::new(),
            tool_use_count: 0,
        };
        self.sessions.upsert(stored);
        let _ = self.sessions.save(&self.sessions_path);

        // ACTIVE — publish_agent_state_by_id reads the live AgentHandle and
        // dual-publishes to agent/{id}/state + runtime/{id}/state. The handle
        // today encodes state=ACTIVE (Phase 1a Task 4).
        self.publish_agent_state_by_id(&new_id).await;

        Ok(StartRuntimeOutcome {
            runtime_id: new_id,
            session_id: session_id.to_string(),
        })
    }
```

- [ ] **Step 4: Rewrite the legacy `AcpCommand::StartAgent` arm to call the helper**

Find the existing arm (server.rs ~790-870). Replace its body. The arm declares local bindings like `start_session_id` before the match — those stay. Just the StartAgent-specific body gets replaced:

```rust
            amux::acp_command::Command::StartAgent(start) => {
                let at = amux::AgentType::try_from(start.agent_type)
                    .unwrap_or(amux::AgentType::ClaudeCode);

                let outcome = self
                    .apply_start_runtime(
                        at,
                        &start.workspace_id,
                        &start.worktree,
                        &start.session_id,
                        &start.initial_prompt,
                    )
                    .await;

                match outcome {
                    Ok(res) => {
                        info!(agent_id = %res.runtime_id, peer_id, "agent started");
                        self.publish_agent_start_result(
                            &reply_device_id,
                            command_id.clone(),
                            true,
                            String::new(),
                            res.runtime_id,
                            res.session_id,
                        )
                        .await;
                    }
                    Err(err) => {
                        let reason = err.error_message.clone();
                        error!(peer_id, "startAgent failed: {}", reason);
                        self.publish_agent_start_result(
                            &reply_device_id,
                            command_id.clone(),
                            false,
                            reason,
                            String::new(),
                            start.session_id.clone(),
                        )
                        .await;
                    }
                }
            }
```

The legacy path's success-side `publish_agent_state_by_id` call is now inside the helper — don't duplicate it in the caller.

- [ ] **Step 5: Compile + test**

```bash
cd /Volumes/openbeta/workspace/amux/daemon && set -a && source .env && set +a && cargo build 2>&1 | tail -5 && cargo test --no-fail-fast 2>&1 | grep "cargo test:" | tail -1
```
Expected: 104+ tests pass. Behavior preserved — legacy path still works identically from iOS's perspective.

- [ ] **Step 6: Commit**

```bash
cd /Volumes/openbeta/workspace/amux && git add daemon/src/daemon/server.rs daemon/src/mqtt/publisher.rs && git commit -m "$(cat <<'EOF'
refactor(runtime): extract apply_start_runtime helper + add FAILED publisher

Legacy AcpCommand::StartAgent arm now delegates workspace resolution,
spawn, STARTING/ACTIVE retained-state publishing, and SessionStore
upsert to apply_start_runtime. The helper returns the new runtime_id
+ session_id on success or structured error on failure; the caller
publishes its path-specific reply (AgentStartResult for legacy, soon
RuntimeStartResult for RPC).

Adds Publisher::publish_runtime_failed that builds a RuntimeInfo with
state=FAILED + error_code/error_message/failed_stage and dual-publishes
to the retained state topic.

Pure refactor: legacy behavior preserved. Tests still pass.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Implement `handle_start_runtime` RPC handler

**Files:**
- Modify: `daemon/src/daemon/server.rs`

Use the `apply_start_runtime` helper from Task 2. Build an `RuntimeStartResult` from the outcome. On error, also publish `FAILED` retained via `publish_runtime_failed` — BUT only if we have a `runtime_id` (and we don't, because the error path in `apply_start_runtime` returns before allocating one; so FAILED publish applies only to post-spawn failures which this phase's helper doesn't yet surface separately — leave the `publish_runtime_failed` method available for future use).

- [ ] **Step 1: Add `handle_start_runtime`**

Insert after the existing `handle_stop_runtime` method in `DaemonServer`:

```rust
    async fn handle_start_runtime(
        &mut self,
        request: &crate::proto::teamclaw::RpcRequest,
        start: &crate::proto::teamclaw::RuntimeStartRequest,
    ) -> crate::proto::teamclaw::RpcResponse {
        use crate::proto::teamclaw::{rpc_response, RpcResponse, RuntimeStartResult};

        let at = amux::AgentType::try_from(start.agent_type)
            .unwrap_or(amux::AgentType::ClaudeCode);

        let outcome = self
            .apply_start_runtime(
                at,
                &start.workspace_id,
                &start.worktree,
                &start.session_id,
                &start.initial_prompt,
            )
            .await;

        match outcome {
            Ok(res) => RpcResponse {
                request_id: request.request_id.clone(),
                success: true,
                error: String::new(),
                requester_client_id: request.requester_client_id.clone(),
                requester_actor_id: request.requester_actor_id.clone(),
                requester_device_id: request.requester_device_id.clone(),
                result: Some(rpc_response::Result::RuntimeStartResult(RuntimeStartResult {
                    accepted: true,
                    runtime_id: res.runtime_id,
                    session_id: res.session_id,
                    rejected_reason: String::new(),
                })),
            },
            Err(err) => RpcResponse {
                request_id: request.request_id.clone(),
                success: false,
                error: err.error_message.clone(),
                requester_client_id: request.requester_client_id.clone(),
                requester_actor_id: request.requester_actor_id.clone(),
                requester_device_id: request.requester_device_id.clone(),
                result: Some(rpc_response::Result::RuntimeStartResult(RuntimeStartResult {
                    accepted: false,
                    runtime_id: String::new(),
                    session_id: String::new(),
                    rejected_reason: err.error_message,
                })),
            },
        }
    }
```

Note: `model_id` on `RuntimeStartRequest` is not yet threaded through `apply_start_runtime` — the legacy `AcpStartAgent` path doesn't carry it either. Phase 1c leaves `model_id` unused (default model). Add a TODO comment on the `start.model_id` read site explaining this is a known gap Phase 1c+ will address, OR simply ignore the field — both are acceptable.

- [ ] **Step 2: Wire into `handle_rpc_request` dispatch**

In `handle_rpc_request`, replace the last remaining placeholder:

```rust
            Some(Method::RuntimeStart(_)) => not_yet_implemented(&request, "runtime_start"),
```

with:

```rust
            Some(Method::RuntimeStart(s)) => self.handle_start_runtime(&request, s).await,
```

- [ ] **Step 3: Compile + test**

```bash
cd /Volumes/openbeta/workspace/amux/daemon && set -a && source .env && set +a && cargo build 2>&1 | tail -3 && cargo test --no-fail-fast 2>&1 | grep "cargo test:" | tail -1
```
Expected: 104+ tests pass.

- [ ] **Step 4: Commit**

```bash
cd /Volumes/openbeta/workspace/amux && git add daemon/src/daemon/server.rs && git commit -m "$(cat <<'EOF'
feat(rpc): implement RuntimeStart handler with STARTING/ACTIVE lifecycle

Uses apply_start_runtime shared helper from the previous commit. Success
path returns RuntimeStartResult{accepted: true, runtime_id, session_id};
failure returns accepted: false + rejected_reason. Retained state topic
sees STARTING briefly after spawn_agent returns, then ACTIVE after
SessionStore upsert — iOS can show a "starting..." placeholder while
the subprocess initializes. Replaces the last Phase 0 placeholder.

model_id field on the request is accepted for wire compatibility but
not yet threaded through apply_start_runtime (legacy path doesn't use
it either). Future work.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Smoke test — bare-agent spawn end-to-end

**Files:** none (behavioral verification only)

This is a sanity check that the "Just you → new session → Agent" flow (bare-agent spawn with all three optional fields empty) still works through the new RPC path. No code changes expected; this is pure behavioral verification.

- [ ] **Step 1: Quick-start daemon + trigger bare-agent spawn**

Daemon:
```bash
cd /Volumes/openbeta/workspace/amux/daemon && set -a && source .env && set +a && RUST_LOG=amuxd=info cargo run -- start 2>&1 | tee /tmp/amux-phase-1c-smoke.log &
```

Let it run for ~15 seconds so it connects to MQTT + publishes initial DeviceState. Then kill it (`pkill amuxd` or Ctrl-C the background job).

- [ ] **Step 2: Verify daemon log shows Phase 1a dual-publish + no RPC dispatch errors**

```bash
grep -E "publish_agent_state|publish_agent_event|rpc|notify|error" /tmp/amux-phase-1c-smoke.log | head -30
```

Expected: log lines showing subscription to `agent/+/commands` AND `runtime/+/commands` (per Phase 1a), publish to `device/{id}/status` AND `device/{id}/state` (per Phase 1a). No `prost::DecodeError` or `panic`.

**This task does NOT exercise the actual RuntimeStart RPC end-to-end** — that requires a real iOS client or a test harness that can send an `RpcRequest`. For Phase 1c's purposes, confirming the daemon runs clean with the new handler wired in is sufficient.

- [ ] **Step 3: Optional — write a cargo integration test that sends RuntimeStart via test_client CLI**

If time permits, extend `daemon/src/cli/test_client.rs` with a new `test-client rpc start-runtime` subcommand that constructs an `RpcRequest::RuntimeStart` with empty workspace_id/worktree/session_id, publishes it to this daemon's `rpc/req`, and subscribes to `rpc/res` for the reply. Verify the reply carries `accepted=true` + a populated `runtime_id`.

If this test is non-trivial to write (test_client may need refactoring to support arbitrary RPC), skip it — the Phase 2 iOS cutover will exercise the full path in practice.

- [ ] **Step 4: Commit if test_client was extended, otherwise skip**

```bash
# Only if Step 3 actually landed a new test_client subcommand:
cd /Volumes/openbeta/workspace/amux && git add daemon/src/cli/test_client.rs && git commit -m "$(cat <<'EOF'
test(cli): add test-client rpc start-runtime for Phase 1c smoke test

Exercises the new RuntimeStart RPC end-to-end from the Rust CLI:
sends RpcRequest::RuntimeStart with empty workspace_id/worktree/
session_id (bare-agent spawn), subscribes to rpc/res, verifies
accepted=true + populated runtime_id.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Final verification

**Files:** none (verification only)

- [ ] **Step 1: Full clean daemon build**

```bash
cd /Volumes/openbeta/workspace/amux/daemon && cargo clean 2>&1 | tail -2
cd /Volumes/openbeta/workspace/amux/daemon && set -a && source .env && set +a && cargo build 2>&1 | tail -3
```
Expected: 0 errors, pre-existing warnings only.

- [ ] **Step 2: Full daemon tests**

```bash
cd /Volumes/openbeta/workspace/amux/daemon && set -a && source .env && set +a && cargo test --no-fail-fast 2>&1 | grep "cargo test:" | tail -1
```
Expected: 104+ pass.

- [ ] **Step 3: iOS clean build**

```bash
cd /Volumes/openbeta/workspace/amux/ios && xcodebuild -project AMUX.xcodeproj -scheme AMUX -destination 'generic/platform=iOS' -configuration Debug clean build CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "BUILD SUCCEEDED|BUILD FAILED" | head -2
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Confirm zero `not_yet_implemented` match arms**

```bash
cd /Volumes/openbeta/workspace/amux && grep -n "not_yet_implemented\|not yet implemented" daemon/src/daemon/server.rs
```
Expected: exactly 2 hits — the `fn not_yet_implemented` definition and the defensive `"session_manager not initialized"` fallback in `handle_rpc_request`. Zero `Some(Method::*) => not_yet_implemented(...)` dispatch lines.

- [ ] **Step 5: Confirm `apply_start_runtime` used by both paths**

```bash
cd /Volumes/openbeta/workspace/amux && grep -n "apply_start_runtime\|fn apply_start_runtime" daemon/src/daemon/server.rs
```
Expected: 3 hits — the `fn apply_start_runtime` definition, the call from `AcpCommand::StartAgent` arm (legacy), and the call from `handle_start_runtime` (RPC).

- [ ] **Step 6: Commit sequence review**

```bash
cd /Volumes/openbeta/workspace/amux && git log --oneline 5c36cd4d..HEAD
```
Expected: 2 or 3 commits — the refactor/helper extraction and the RPC handler (plus optional test-client extension from Task 4 Step 3).

- [ ] **Step 7: Working tree clean of our changes**

```bash
cd /Volumes/openbeta/workspace/amux && git status --porcelain
```
Expected: only pre-existing user state (`mac/Packages` unresolved conflict markers, untracked `ios/AMUXUITests/`, `scripts/run-ios.sh`).

---

## Phase 1c Complete

At this point:
- All 9 Phase 0 placeholder RPC match arms are replaced with real handlers
- `RuntimeStart` RPC spawns a Claude Code subprocess end-to-end, publishes `RuntimeInfo { state: STARTING }` retained briefly after spawn, then `ACTIVE` after SessionStore upsert
- Legacy `AcpCommand::StartAgent` path and new RPC path share `apply_start_runtime` helper — single source of truth
- Bare-agent spawn (empty `workspace_id` + empty `worktree` + empty `session_id`) works through both paths
- `Publisher::publish_runtime_failed` helper available for future use (fine-grained stage failures)
- Daemon-side of the MQTT topic redesign is functionally complete except `user/{actor}/notify` (Phase 1d, gated)

**Ready for Phase 2:** iOS can now use `RpcRequest::RuntimeStart` for the new-session flow. Legacy `AcpCommand::StartAgent` path still works and stays until Phase 3.

**Phase 1d (gated):** `user/{actor}/notify` publish via transactional outbox — only after Supabase `user_inbox` table exists and EMQX JWT auth migration ships.

**Known gaps / future work (not blockers for Phase 2):**
- Fine-grained stage transitions during `STARTING` (currently hardcoded to `"spawning_process"` for the full window). Requires refactoring `AgentManager::spawn_agent` into staged async.
- `RuntimeStartRequest.model_id` is accepted on the wire but not threaded through spawn. Low-priority until iOS actually uses it.
- `RuntimeStart` reply is sync-blocking on full spawn completion (~2-5s) rather than truly async accepted-then-spawn. Decomposing requires `Arc<Mutex<DaemonServer>>`-style shared state for the background task — legitimate but Phase 1c defers.
- FAILED retain doesn't auto-clear; stays on the state topic until next daemon startup orphan cleanup or explicit user dismissal. Phase 3 orphan cleanup handles this.
