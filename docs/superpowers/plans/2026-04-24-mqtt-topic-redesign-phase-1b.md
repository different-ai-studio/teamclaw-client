# MQTT Topic Redesign — Phase 1b Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace 8 of the 9 Phase 0 placeholder `Method::*` match arms in `session_manager.rs` with real RPC handlers — `FetchPeers`, `FetchWorkspaces`, `AnnouncePeer`, `DisconnectPeer`, `AddWorkspace`, `RemoveWorkspace`, `RemoveMember`, `StopRuntime`. Each handler delegates to (or extracts shared helpers from) the existing collab-path logic that today handles the same operation on `DeviceCollabCommand`. State-changing handlers additionally publish `Notify` hints to `device/{id}/notify` so Phase 2 iOS can invalidate local caches. `RuntimeStart` stays placeholder — the full runtime lifecycle state machine ships as its own plan (Phase 1c). Zero iOS changes.

**Architecture:** The current RPC dispatch lives entirely in `daemon/src/teamclaw/session_manager.rs`, which was fine while every RPC was session/task-scoped. The 8 non-session RPC methods need access to `PeerTracker`, `WorkspaceStore`, `AuthManager`, `AgentManager`, etc. — all of which live on `DaemonServer`, not `SessionManager`. The refactor: lift the RPC dispatch up to `DaemonServer`, which matches on `RpcRequest.method`, delegates session-scoped methods to `SessionManager` (unchanged behavior), and handles non-session methods locally with direct access to the state they need. Existing collab-path handlers in `server.rs` (around lines 1049-1164) get extracted into shareable `async fn handle_<op>(...)` methods so both the legacy collab path and the new RPC path call the same implementation.

**Tech Stack:** Rust, prost, rumqttc. No new dependencies. Changes are confined to `daemon/src/daemon/server.rs` and `daemon/src/teamclaw/session_manager.rs`, plus minor edits to `daemon/src/mqtt/publisher.rs` for the new `publish_notify` helper.

**Reference:** `docs/superpowers/specs/2026-04-24-mqtt-topic-redesign-design.md` — "Migration Plan → Phase 1" section (the RPC handler part) and "Peers recovery model" section.

**Out of scope for Phase 1b:**
- `RuntimeStart` handler — its own Phase 1c plan. The full runtime lifecycle state machine (`STARTING` → stage transitions → `ACTIVE` / `FAILED` with populated `stage`/`error_*` fields) is substantial enough to warrant its own plan. Placeholder arm stays returning `"runtime_start not yet implemented"`.
- `user/{actor}/notify` publishes + transactional outbox — Phase 1d (gated on Supabase `user_inbox` table + EMQX JWT auth prereqs).
- iOS switchover to RPC — Phase 2.
- Retaining `device/{id}/peers` and `device/{id}/workspaces` publishes — daemon keeps publishing them during the compat window. Phase 3 retires them.

---

## File Structure

**Rust files edited:**
- `daemon/src/daemon/server.rs` — add `handle_rpc_request_v2` (or rename existing — see Task 2) that dispatches at the server level; extract `handle_<op>` helpers from existing collab match arms so RPC and collab call the same code; add the 8 new handler methods
- `daemon/src/teamclaw/session_manager.rs` — extract session/task-scoped dispatch into `handle_rpc_method(request: RpcRequest, host_primary_agent_id: Option<String>) -> RpcResponse` that ONLY handles the session/task variants; delete the 8 non-session placeholder arms (they move to server.rs)
- `daemon/src/mqtt/publisher.rs` — add `publish_notify(&Notify)` helper that publishes to `device/{id}/notify` (retain: false)

**Expected test additions:**
- `daemon/src/teamclaw/session_manager.rs` tests for the refactored dispatch
- Possibly integration-style tests in `daemon/tests/teamclaw_mqtt_rearchitecture.rs` for new RPC handlers. Handler unit tests where mocking is tractable.

**Behavior at end of Phase 1b:**
- `FetchPeers` / `FetchWorkspaces` return the live daemon state
- `AnnouncePeer` / `DisconnectPeer` mutate `PeerTracker` and publish `Notify { event_type: "peers.changed" }` on `device/{id}/notify`
- `AddWorkspace` / `RemoveWorkspace` mutate `WorkspaceStore` + Supabase and publish `Notify { event_type: "workspaces.changed" }`
- `RemoveMember` mutates auth + Supabase and publishes `Notify { event_type: "members.changed" }`
- `StopRuntime` terminates the runtime via `AgentManager` and publishes `RuntimeInfo { state: STOPPED, ... }` to the retained `runtime/{id}/state` (dual-published to `agent/{id}/state` per Phase 1a). Retain cleanup happens after a grace window.
- `RuntimeStart` still returns `"runtime_start not yet implemented"`.
- Legacy `DeviceCollabCommand` path still works — it and the new RPC handlers both call the extracted `handle_<op>` helpers.
- iOS still uses legacy `/collab` path; Phase 2 will switch it to RPC.

---

## Task 1: Verify green baseline

**Files:** none (verification only)

- [ ] **Step 1: Confirm daemon builds + 104 tests pass**

```bash
cd /Volumes/openbeta/workspace/amux/daemon && set -a && source .env && set +a && cargo build 2>&1 | tail -3 && cargo test --no-fail-fast 2>&1 | grep "cargo test:" | tail -1
```
Expected: `Finished \`dev\` profile`; `cargo test: 104 passed` (or higher — count drifted during Phase 1a but all pass).

- [ ] **Step 2: Confirm iOS builds**

```bash
cd /Volumes/openbeta/workspace/amux/ios && xcodebuild -project AMUX.xcodeproj -scheme AMUX -destination 'generic/platform=iOS' -configuration Debug build CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "BUILD SUCCEEDED|BUILD FAILED" | head -2
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Confirm HEAD is at Phase 1a + broker-fix final**

```bash
cd /Volumes/openbeta/workspace/amux && git log --oneline -3
```
Expected: top commit is `1216419f docs: scrub remaining HiveMQ references in code comments` (or later).

No commit in this task.

---

## Task 2: Refactor — lift RPC dispatch from `SessionManager` to `DaemonServer`

**Files:**
- Modify: `daemon/src/daemon/server.rs`
- Modify: `daemon/src/teamclaw/session_manager.rs`

The existing `session_manager.rs::handle_rpc_request(topic, payload, primary_agent_id)` parses the wire payload and matches on every `Method::*` variant. Non-session methods (the 9 Phase 0 placeholders) live there for historical reasons — they were added in Phase 0 where minimal changes to existing files were preferred. They belong in `DaemonServer` where the state they need lives.

Structure after this task:
- `DaemonServer::handle_rpc_request(topic, payload)` — new. Parses the wire payload, matches on `Method`, delegates to either `self.session_manager.handle_rpc_method(req)` (for session/task methods) or local handlers (for peer/workspace/member/runtime methods, all still returning `"not yet implemented"` errors at the end of this task — the real handler bodies land in Tasks 3-9).
- `SessionManager::handle_rpc_method(request, primary_agent_id) -> RpcResponse` — renamed from `handle_rpc_request`, no longer takes topic/payload (caller parses), returns response directly (caller publishes). Only dispatches the session/task variants. Returns `RpcResponse::error` with a clear message if called with a non-session method (defensive).

- [ ] **Step 1: Read the current `session_manager.rs::handle_rpc_request` implementation**

```bash
sed -n '90,260p' /Volumes/openbeta/workspace/amux/daemon/src/teamclaw/session_manager.rs
```

Identify:
- The `match &request.method` arms (~line 106 onward)
- The placeholder arms added in Phase 0 for non-session methods
- How the response is published (likely via `self.rpc_server.publish_response(topic, request_id, response)` or similar)

- [ ] **Step 2: Split the dispatch — keep session methods in `SessionManager`, move non-session to `DaemonServer`**

In `daemon/src/teamclaw/session_manager.rs`:

Rename the existing `handle_rpc_request(topic, payload, primary_agent_id)` to `handle_rpc_method(request: RpcRequest, primary_agent_id: Option<String>) -> RpcResponse`. Remove the wire-format parsing at the top (caller does it). Remove the response-publishing at the bottom (caller does it). Keep only the session/task arms:

```rust
    pub async fn handle_rpc_method(
        &mut self,
        request: RpcRequest,
        primary_agent_id: Option<String>,
    ) -> RpcResponse {
        let request_id = request.request_id.clone();
        match request.method {
            Some(teamclaw::rpc_request::Method::CreateSession(r)) => {
                self.handle_create_session(request_id, r, primary_agent_id).await
            }
            Some(teamclaw::rpc_request::Method::FetchSession(r)) => {
                self.handle_fetch_session(request_id, r).await
            }
            Some(teamclaw::rpc_request::Method::FetchSessionMessages(r)) => {
                self.handle_fetch_session_messages(request_id, r).await
            }
            Some(teamclaw::rpc_request::Method::JoinSession(r)) => {
                self.handle_join_session(request_id, r).await
            }
            Some(teamclaw::rpc_request::Method::AddParticipant(r)) => {
                self.handle_add_participant(request_id, r).await
            }
            Some(teamclaw::rpc_request::Method::RemoveParticipant(r)) => {
                self.handle_remove_participant(request_id, r).await
            }
            Some(teamclaw::rpc_request::Method::CreateTask(r)) => {
                self.handle_create_task(request_id, r).await
            }
            Some(teamclaw::rpc_request::Method::ClaimTask(r)) => {
                self.handle_claim_task(request_id, r).await
            }
            Some(teamclaw::rpc_request::Method::SubmitTask(r)) => {
                self.handle_submit_task(request_id, r).await
            }
            Some(teamclaw::rpc_request::Method::UpdateTask(r)) => {
                self.handle_update_task(request_id, r).await
            }
            other => {
                // Non-session methods are dispatched by DaemonServer directly,
                // not SessionManager. If we land here, the caller routed wrong.
                warn!(?other, "SessionManager got non-session RPC method; routing bug");
                RpcResponse {
                    request_id,
                    success: false,
                    error: "method not handled by SessionManager".to_string(),
                    requester_client_id: request.requester_client_id,
                    requester_actor_id: request.requester_actor_id,
                    requester_device_id: request.requester_device_id,
                    result: None,
                }
            }
        }
    }
```

Delete the 9 non-session placeholder arms (RuntimeStart / RuntimeStop / AnnouncePeer / DisconnectPeer / RemoveMember / AddWorkspace / RemoveWorkspace / FetchPeers / FetchWorkspaces) — they move to server.rs in Step 3.

**Preserve the exact method signatures of `handle_create_session` etc. inside SessionManager.** Their bodies are unchanged.

- [ ] **Step 3: Add `DaemonServer::handle_rpc_request` with skeleton dispatch**

In `/Volumes/openbeta/workspace/amux/daemon/src/daemon/server.rs`, add a new method (the exact insertion point depends on where other incoming-message handlers live; look for `handle_incoming` and place near it):

```rust
    async fn handle_rpc_request(&mut self, topic: &str, payload: &[u8]) {
        use crate::proto::teamclaw::{rpc_request::Method, RpcRequest, RpcResponse};
        use prost::Message;

        let request = match RpcRequest::decode(payload) {
            Ok(r) => r,
            Err(e) => {
                warn!(%topic, "failed to decode RpcRequest: {}", e);
                return;
            }
        };

        let request_id = request.request_id.clone();

        let response: RpcResponse = match &request.method {
            // ─── Session/task methods — delegate to SessionManager ───
            Some(Method::CreateSession(_))
            | Some(Method::FetchSession(_))
            | Some(Method::FetchSessionMessages(_))
            | Some(Method::JoinSession(_))
            | Some(Method::AddParticipant(_))
            | Some(Method::RemoveParticipant(_))
            | Some(Method::CreateTask(_))
            | Some(Method::ClaimTask(_))
            | Some(Method::SubmitTask(_))
            | Some(Method::UpdateTask(_)) => {
                if let Some(tc) = self.session_manager.as_mut() {
                    let primary = self.primary_agent_id();
                    tc.handle_rpc_method(request.clone(), primary).await
                } else {
                    not_yet_implemented(&request, "session_manager not initialized")
                }
            }
            // ─── Non-session methods — handle locally ───
            // Phase 1b Tasks 3-9 replace these stubs with real handlers.
            Some(Method::FetchPeers(_)) => not_yet_implemented(&request, "fetch_peers"),
            Some(Method::FetchWorkspaces(_)) => not_yet_implemented(&request, "fetch_workspaces"),
            Some(Method::AnnouncePeer(_)) => not_yet_implemented(&request, "announce_peer"),
            Some(Method::DisconnectPeer(_)) => not_yet_implemented(&request, "disconnect_peer"),
            Some(Method::AddWorkspace(_)) => not_yet_implemented(&request, "add_workspace"),
            Some(Method::RemoveWorkspace(_)) => not_yet_implemented(&request, "remove_workspace"),
            Some(Method::RemoveMember(_)) => not_yet_implemented(&request, "remove_member"),
            Some(Method::RuntimeStop(_)) => not_yet_implemented(&request, "runtime_stop"),
            Some(Method::RuntimeStart(_)) => not_yet_implemented(&request, "runtime_start"),
            None => RpcResponse {
                request_id,
                success: false,
                error: "no method".to_string(),
                requester_client_id: request.requester_client_id,
                requester_actor_id: request.requester_actor_id,
                requester_device_id: request.requester_device_id,
                result: None,
            },
        };

        // Publish response on this device's rpc/res topic.
        let res_topic = self.mqtt.topics.device_rpc_res();
        let bytes = response.encode_to_vec();
        if let Err(e) = self
            .mqtt
            .client
            .publish(res_topic, rumqttc::QoS::AtLeastOnce, false, bytes)
            .await
        {
            warn!("failed to publish RpcResponse: {}", e);
        }
    }
```

And add a free function `not_yet_implemented` in the same file (scope it `fn` — no `pub`):

```rust
fn not_yet_implemented(
    request: &crate::proto::teamclaw::RpcRequest,
    method_name: &str,
) -> crate::proto::teamclaw::RpcResponse {
    crate::proto::teamclaw::RpcResponse {
        request_id: request.request_id.clone(),
        success: false,
        error: format!("{} not yet implemented", method_name),
        requester_client_id: request.requester_client_id.clone(),
        requester_actor_id: request.requester_actor_id.clone(),
        requester_device_id: request.requester_device_id.clone(),
        result: None,
    }
}
```

If `primary_agent_id` doesn't already exist as a method on DaemonServer, extract the inline `// Pre-compute the host's primary agent_id...` logic from the old dispatch site (around line 553) into a helper method:

```rust
    fn primary_agent_id(&self) -> Option<String> {
        // Existing inline logic from the pre-refactor dispatch site
        // ...
    }
```

- [ ] **Step 4: Route `IncomingMessage::TeamclawRpc` to the new server-level dispatch**

In `server.rs::handle_incoming`, find the existing arm:

```rust
            subscriber::IncomingMessage::TeamclawRpc { topic, payload } => {
                // Pre-compute the host's primary agent_id so SessionManager...
                let primary = /* ... */;
                if let Some(tc) = self.session_manager.as_mut() {
                    tc.handle_rpc_request(&topic, &payload, primary).await;
                }
            }
```

Replace with:

```rust
            subscriber::IncomingMessage::TeamclawRpc { topic, payload } => {
                self.handle_rpc_request(&topic, &payload).await;
            }
```

- [ ] **Step 5: Compile + test**

```bash
cd /Volumes/openbeta/workspace/amux/daemon && set -a && source .env && set +a && cargo build 2>&1 | tail -5 && cargo test --no-fail-fast 2>&1 | grep "cargo test:" | tail -1
```
Expected: clean build; `cargo test: 104 passed` (no new tests, no regressions — the refactor is semantics-preserving).

If tests fail, the most likely cause is that the old `session_manager.rs::handle_rpc_request` signature change broke callers other than the one in server.rs. Check with `grep -rn "handle_rpc_request" daemon/` — there should be no remaining callers of the old name.

- [ ] **Step 6: Commit**

```bash
cd /Volumes/openbeta/workspace/amux && git add daemon/src/daemon/server.rs daemon/src/teamclaw/session_manager.rs && git commit -m "$(cat <<'EOF'
refactor(rpc): lift dispatch from SessionManager to DaemonServer

Session/task methods (CreateSession, FetchSession, AddParticipant,
CreateTask, etc.) stay in SessionManager::handle_rpc_method. Non-session
methods (Fetch/Announce/Disconnect/Add/Remove Peer/Workspace/Member,
plus RuntimeStart/Stop) dispatch at DaemonServer::handle_rpc_request
where access to PeerTracker, WorkspaceStore, AuthManager, and
AgentManager lives. All 9 non-session methods still return
"not yet implemented" placeholders — Phase 1b Tasks 3-9 replace them.
Pure refactor: wire behavior unchanged.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Implement `FetchPeers` and `FetchWorkspaces`

**Files:**
- Modify: `daemon/src/daemon/server.rs`

These are the simplest two handlers — pure reads, no mutation, no notify. Implement together since they share the same shape.

- [ ] **Step 1: Add `handle_fetch_peers` to `DaemonServer`**

In `daemon/src/daemon/server.rs`, add a method:

```rust
    async fn handle_fetch_peers(
        &self,
        request: &crate::proto::teamclaw::RpcRequest,
    ) -> crate::proto::teamclaw::RpcResponse {
        use crate::proto::teamclaw::{rpc_response, FetchPeersResult, RpcResponse};

        let peers = self.peers.to_proto_peer_list().peers;
        RpcResponse {
            request_id: request.request_id.clone(),
            success: true,
            error: String::new(),
            requester_client_id: request.requester_client_id.clone(),
            requester_actor_id: request.requester_actor_id.clone(),
            requester_device_id: request.requester_device_id.clone(),
            result: Some(rpc_response::Result::FetchPeersResult(FetchPeersResult {
                peers,
            })),
        }
    }
```

Note: `self.peers.to_proto_peer_list()` returns `amux::PeerList` (exists today); its `.peers` field is a `Vec<amux::PeerInfo>`. `FetchPeersResult.peers` takes the same type (see Phase 0 Task 11 definition).

- [ ] **Step 2: Add `handle_fetch_workspaces` to `DaemonServer`**

```rust
    async fn handle_fetch_workspaces(
        &self,
        request: &crate::proto::teamclaw::RpcRequest,
    ) -> crate::proto::teamclaw::RpcResponse {
        use crate::proto::teamclaw::{rpc_response, FetchWorkspacesResult, RpcResponse};

        let workspaces = self.workspaces.to_proto_list().workspaces;
        RpcResponse {
            request_id: request.request_id.clone(),
            success: true,
            error: String::new(),
            requester_client_id: request.requester_client_id.clone(),
            requester_actor_id: request.requester_actor_id.clone(),
            requester_device_id: request.requester_device_id.clone(),
            result: Some(rpc_response::Result::FetchWorkspacesResult(
                FetchWorkspacesResult { workspaces },
            )),
        }
    }
```

Note: `self.workspaces.to_proto_list()` — verify the exact method name on `WorkspaceStore` with `grep -n "fn to_proto" daemon/src/config/workspace_store.rs` before writing; adapt the call if the method name differs.

- [ ] **Step 3: Wire the two handlers into the dispatch**

In `handle_rpc_request`, replace the two placeholder lines:

```rust
            Some(Method::FetchPeers(_)) => not_yet_implemented(&request, "fetch_peers"),
            Some(Method::FetchWorkspaces(_)) => not_yet_implemented(&request, "fetch_workspaces"),
```

with:

```rust
            Some(Method::FetchPeers(_)) => self.handle_fetch_peers(&request).await,
            Some(Method::FetchWorkspaces(_)) => self.handle_fetch_workspaces(&request).await,
```

- [ ] **Step 4: Compile + test**

```bash
cd /Volumes/openbeta/workspace/amux/daemon && set -a && source .env && set +a && cargo build 2>&1 | tail -3 && cargo test --no-fail-fast 2>&1 | grep "cargo test:" | tail -1
```
Expected: clean; 104+ tests pass.

- [ ] **Step 5: Commit**

```bash
cd /Volumes/openbeta/workspace/amux && git add daemon/src/daemon/server.rs && git commit -m "$(cat <<'EOF'
feat(rpc): implement FetchPeers and FetchWorkspaces handlers

Both are pure reads: FetchPeers returns the daemon's in-memory
PeerTracker snapshot; FetchWorkspaces returns the WorkspaceStore
snapshot. No mutation, no notify. Replaces two of the nine Phase 0
placeholder match arms.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Add `Publisher::publish_notify` helper

**Files:**
- Modify: `daemon/src/mqtt/publisher.rs`

A reusable helper for publishing `Notify` messages on `device/{id}/notify`. Used by Tasks 5-7 below when they mutate peer/workspace/member state and need to invalidate subscribers.

- [ ] **Step 1: Add the method to `Publisher`**

In `daemon/src/mqtt/publisher.rs`, append to the `impl<'a> Publisher<'a> { ... }` block:

```rust
    /// Publishes a Notify hint to the daemon's own device/{id}/notify topic.
    /// Ephemeral (no retain) — receivers react by re-fetching authoritative
    /// state from Supabase or daemon RPC.
    pub async fn publish_notify(
        &self,
        event_type: &str,
        refresh_hint: &str,
    ) -> Result<(), rumqttc::ClientError> {
        use crate::proto::teamclaw::Notify;
        let notify = Notify {
            event_type: event_type.to_string(),
            refresh_hint: refresh_hint.to_string(),
            sent_at: chrono::Utc::now().timestamp(),
        };
        self.client
            .client
            .publish(
                self.client.topics.device_notify(),
                QoS::AtLeastOnce,
                false,
                prost::Message::encode_to_vec(&notify),
            )
            .await
    }
```

(If `prost::Message::encode_to_vec` isn't already in scope, add `use prost::Message as _;` at the top of the file.)

- [ ] **Step 2: Compile**

```bash
cd /Volumes/openbeta/workspace/amux/daemon && set -a && source .env && set +a && cargo build 2>&1 | tail -3
```
Expected: clean. The method is unused yet; `warn(dead_code)` is harmless until Task 5 calls it.

- [ ] **Step 3: Commit**

```bash
cd /Volumes/openbeta/workspace/amux && git add daemon/src/mqtt/publisher.rs && git commit -m "$(cat <<'EOF'
feat(mqtt): add Publisher::publish_notify helper for device/{id}/notify

Used by RPC handlers that mutate peer/workspace/member state. Ephemeral
(no retain) — consumers re-fetch authoritative state on hint.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Implement `AnnouncePeer` and `DisconnectPeer`

**Files:**
- Modify: `daemon/src/daemon/server.rs`

Both operations currently live as `DeviceCollabCommand::Command::PeerAnnounce` / `PeerDisconnect` arms in the collab handler (around line 1049 / 1074 of `server.rs`). Extract the core logic into helpers so RPC and collab paths share an implementation. Publish `Notify { event_type: "peers.changed" }` after each.

- [ ] **Step 1: Read the existing collab handlers**

```bash
sed -n '1049,1100p' /Volumes/openbeta/workspace/amux/daemon/src/daemon/server.rs
```

Identify:
- Inputs the collab arms receive (a `PeerAnnounce` / `PeerDisconnect` message, possibly peer_id from envelope)
- Side effects (mutations on `self.peers`, possibly auth validation via `self.auth`, publish of peer list / collab event)
- Outputs (success/error via collab event publish)

- [ ] **Step 2: Extract a shared `handle_peer_announce` helper on `DaemonServer`**

Create a new method that takes the announce payload + sender context and performs the mutation + returns a structured result:

```rust
    /// Applies a peer announcement. Returns (accepted, error_text, assigned_role).
    /// Shared by the legacy collab path and the RPC AnnouncePeer method.
    /// DOES NOT publish anything — the caller is responsible for broadcasts
    /// (legacy collab arm republishes peer_list + workspace_list; new RPC
    /// handler publishes Notify "peers.changed").
    async fn apply_peer_announce(
        &mut self,
        announce: &amux::PeerAnnounce,
    ) -> (bool, String, amux::MemberRole) {
        use crate::collab::auth::AuthResult;
        use crate::collab::peers::PeerState;

        match self.auth.authenticate(&announce.auth_token) {
            AuthResult::Accepted { member } => {
                let role = if member.is_owner() {
                    amux::MemberRole::Owner
                } else {
                    amux::MemberRole::Member
                };
                let pi = announce.peer.as_ref();
                let peer_id_str = pi.map(|p| p.peer_id.clone()).unwrap_or_default();
                info!(peer_id = %peer_id_str, member_id = %member.member_id, "peer authenticated");
                self.peers.add_peer(PeerState {
                    peer_id: peer_id_str,
                    member_id: member.member_id.clone(),
                    display_name: member.display_name.clone(),
                    device_type: pi.map(|p| p.device_type.clone()).unwrap_or_default(),
                    role,
                    connected_at: chrono::Utc::now().timestamp(),
                });
                (true, String::new(), role)
            }
            AuthResult::Rejected { reason } => {
                warn!(%reason, "peer rejected");
                (false, reason, amux::MemberRole::Member)
            }
        }
    }

    /// Applies a peer disconnect. Returns (accepted, error_text).
    async fn apply_peer_disconnect(&mut self, peer_id: &str) -> (bool, String) {
        if self.peers.remove_peer(peer_id).is_some() {
            info!(peer_id, "peer disconnected");
            (true, String::new())
        } else {
            (false, format!("unknown peer_id: {}", peer_id))
        }
    }
```

**Update the legacy collab arms to call these helpers:**

The existing `PeerAnnounce` arm (lines 1049-1073 of server.rs) currently inlines the auth + mutation + `publish_peer_list` + `publish_workspace_list` calls. Replace the entire arm body with:

```rust
            amux::device_collab_command::Command::PeerAnnounce(announce) => {
                let (accepted, _error, _role) = self.apply_peer_announce(announce).await;
                if accepted {
                    // Legacy behavior: new peer sees current state via retained
                    // peer_list / workspace_list publishes. Phase 3 replaces
                    // these with FetchPeers/FetchWorkspaces RPC + notify.
                    let publisher = Publisher::new(&self.mqtt);
                    let _ = publisher.publish_peer_list(&self.peers.to_proto_peer_list()).await;
                    let _ = publisher.publish_workspace_list(&self.workspaces.to_proto_list()).await;
                }
            }
```

And `PeerDisconnect` (lines 1074-1079):

```rust
            amux::device_collab_command::Command::PeerDisconnect(_) => {
                let (accepted, _error) = self.apply_peer_disconnect(&peer_id).await;
                if accepted {
                    let publisher = Publisher::new(&self.mqtt);
                    let _ = publisher.publish_peer_list(&self.peers.to_proto_peer_list()).await;
                }
            }
```

- [ ] **Step 3: Update the legacy collab arms to call the helpers**

In the existing `DeviceCollabCommand::Command::PeerAnnounce(announce) => { ... }` arm, replace the extracted body with:

```rust
                let (accepted, error, assigned_role) = self.apply_peer_announce(announce).await;
                // (preserve whatever collab-event publish the original
                //  arm did — just source the fields from the helper result)
```

Same pattern for `PeerDisconnect`.

- [ ] **Step 4: Add the two RPC handlers**

```rust
    async fn handle_announce_peer(
        &mut self,
        request: &crate::proto::teamclaw::RpcRequest,
        announce: &crate::proto::teamclaw::AnnouncePeerRequest,
    ) -> crate::proto::teamclaw::RpcResponse {
        use crate::proto::teamclaw::{rpc_response, AnnouncePeerResult, RpcResponse};

        // AnnouncePeerRequest in teamclaw.proto carries amux.PeerInfo and auth_token;
        // we construct an amux::PeerAnnounce that apply_peer_announce expects.
        let amux_announce = amux::PeerAnnounce {
            peer: announce.peer.clone(),
            auth_token: announce.auth_token.clone(),
        };
        let (accepted, error, assigned_role) = self.apply_peer_announce(&amux_announce).await;

        // Hint subscribers to re-fetch peers.
        if accepted {
            let publisher = Publisher::new(&self.mqtt);
            let _ = publisher.publish_notify("peers.changed", "").await;
        }

        RpcResponse {
            request_id: request.request_id.clone(),
            success: accepted,
            error,
            requester_client_id: request.requester_client_id.clone(),
            requester_actor_id: request.requester_actor_id.clone(),
            requester_device_id: request.requester_device_id.clone(),
            result: Some(rpc_response::Result::AnnouncePeerResult(AnnouncePeerResult {
                accepted,
                error: String::new(), // success field above already carries accepted; error field in Result is redundant. See teamclaw.proto Phase 0 Task 11.
                assigned_role: assigned_role as i32,
            })),
        }
    }

    async fn handle_disconnect_peer(
        &mut self,
        request: &crate::proto::teamclaw::RpcRequest,
        disconnect: &crate::proto::teamclaw::DisconnectPeerRequest,
    ) -> crate::proto::teamclaw::RpcResponse {
        use crate::proto::teamclaw::{rpc_response, DisconnectPeerResult, RpcResponse};

        let amux_disconnect = amux::PeerDisconnect {};
        let (accepted, error) = self.apply_peer_disconnect(
            &amux_disconnect,
            Some(disconnect.peer_id.clone()),
        ).await;

        if accepted {
            let publisher = Publisher::new(&self.mqtt);
            let _ = publisher.publish_notify("peers.changed", "").await;
        }

        RpcResponse {
            request_id: request.request_id.clone(),
            success: accepted,
            error: error.clone(),
            requester_client_id: request.requester_client_id.clone(),
            requester_actor_id: request.requester_actor_id.clone(),
            requester_device_id: request.requester_device_id.clone(),
            result: Some(rpc_response::Result::DisconnectPeerResult(DisconnectPeerResult {
                accepted,
                error,
            })),
        }
    }
```

- [ ] **Step 5: Wire into dispatch**

In `handle_rpc_request`, replace:
```rust
            Some(Method::AnnouncePeer(_)) => not_yet_implemented(&request, "announce_peer"),
            Some(Method::DisconnectPeer(_)) => not_yet_implemented(&request, "disconnect_peer"),
```
with:
```rust
            Some(Method::AnnouncePeer(ann)) => self.handle_announce_peer(&request, ann).await,
            Some(Method::DisconnectPeer(d)) => self.handle_disconnect_peer(&request, d).await,
```

- [ ] **Step 6: Compile + test**

```bash
cd /Volumes/openbeta/workspace/amux/daemon && set -a && source .env && set +a && cargo build 2>&1 | tail -3 && cargo test --no-fail-fast 2>&1 | grep "cargo test:" | tail -1
```
Expected: clean; 104+ tests pass.

- [ ] **Step 7: Commit**

```bash
cd /Volumes/openbeta/workspace/amux && git add daemon/src/daemon/server.rs && git commit -m "$(cat <<'EOF'
feat(rpc): implement AnnouncePeer and DisconnectPeer handlers

Extract apply_peer_announce / apply_peer_disconnect helpers shared by
the legacy DeviceCollabCommand path and the new RPC handlers. Both RPC
handlers publish Notify{event_type: "peers.changed"} to device/{id}/notify
on success so Phase 2 iOS can invalidate its local peer cache.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Implement `AddWorkspace` and `RemoveWorkspace`

**Files:**
- Modify: `daemon/src/daemon/server.rs`

Same pattern as Task 5. Legacy arms at server.rs:1099 / server.rs:1151. Extract `apply_add_workspace` / `apply_remove_workspace` helpers. New RPC handlers publish `Notify { event_type: "workspaces.changed" }`.

- [ ] **Step 1: Read existing collab arms**

```bash
sed -n '1099,1170p' /Volumes/openbeta/workspace/amux/daemon/src/daemon/server.rs
```
Identify the mutation pattern (WorkspaceStore upsert/remove, Supabase sync, collab-event publish).

- [ ] **Step 2: Extract `apply_add_workspace` and `apply_remove_workspace` helpers**

```rust
    /// Applies a workspace add. Returns (success, error_text, resulting_workspace_if_any).
    /// Caller publishes any collab event or Notify hint.
    async fn apply_add_workspace(
        &mut self,
        add: &amux::AddWorkspace,
    ) -> (bool, String, Option<amux::WorkspaceInfo>) {
        match self.workspaces.add(&add.path) {
            Ok(outcome) => {
                let mut ws = outcome.workspace;
                let mut should_save = outcome.inserted;
                if self.sync_workspace_to_supabase(&mut ws).await {
                    should_save = true;
                }
                if let Some(existing) = self
                    .workspaces
                    .workspaces
                    .iter_mut()
                    .find(|w| w.workspace_id == ws.workspace_id)
                {
                    *existing = ws.clone();
                }
                if should_save {
                    let _ = self.workspaces.save(&self.workspaces_path);
                }
                info!(workspace_id = %ws.workspace_id, path = %ws.path, "workspace added");
                let info = amux::WorkspaceInfo {
                    workspace_id: ws.workspace_id,
                    path: ws.path,
                    display_name: ws.display_name,
                };
                (true, String::new(), Some(info))
            }
            Err(e) => {
                warn!(path = %add.path, "add workspace failed: {}", e);
                (false, e.to_string(), None)
            }
        }
    }

    /// Applies a workspace remove. Returns (success, error_text).
    async fn apply_remove_workspace(
        &mut self,
        remove: &amux::RemoveWorkspace,
    ) -> (bool, String) {
        if self.workspaces.remove(&remove.workspace_id) {
            let _ = self.workspaces.save(&self.workspaces_path);
            info!(workspace_id = %remove.workspace_id, "workspace removed");
            (true, String::new())
        } else {
            (false, format!("unknown workspace_id: {}", remove.workspace_id))
        }
    }
```

- [ ] **Step 3: Update legacy collab arms to call the helpers**

Replace the `AddWorkspace` arm (lines 1099-1150 of server.rs) with:

```rust
            amux::device_collab_command::Command::AddWorkspace(add) => {
                let (success, error, workspace) = self.apply_add_workspace(add).await;
                let _ = publisher
                    .publish_workspace_list(&self.workspaces.to_proto_list())
                    .await;
                let event = amux::DeviceCollabEvent {
                    device_id: self.config.device.id.clone(),
                    timestamp: chrono::Utc::now().timestamp(),
                    event: Some(amux::device_collab_event::Event::WorkspaceResult(
                        amux::WorkspaceResult {
                            command_id,
                            success,
                            error,
                            workspace,
                        },
                    )),
                };
                let _ = publisher.publish_device_collab_event(&event).await;
            }
```

And `RemoveWorkspace` (lines 1151-1157):

```rust
            amux::device_collab_command::Command::RemoveWorkspace(remove) => {
                let (success, _error) = self.apply_remove_workspace(remove).await;
                if success {
                    let _ = publisher
                        .publish_workspace_list(&self.workspaces.to_proto_list())
                        .await;
                }
            }
```

- [ ] **Step 4: Add the two RPC handlers**

```rust
    async fn handle_add_workspace(
        &mut self,
        request: &crate::proto::teamclaw::RpcRequest,
        add: &crate::proto::teamclaw::AddWorkspaceRequest,
    ) -> crate::proto::teamclaw::RpcResponse {
        use crate::proto::teamclaw::{rpc_response, AddWorkspaceResult, RpcResponse};

        let amux_add = amux::AddWorkspace { path: add.path.clone() };
        let (accepted, error, workspace) = self.apply_add_workspace(&amux_add).await;

        if accepted {
            let publisher = Publisher::new(&self.mqtt);
            let _ = publisher.publish_notify("workspaces.changed", "").await;
        }

        RpcResponse {
            request_id: request.request_id.clone(),
            success: accepted,
            error: error.clone(),
            requester_client_id: request.requester_client_id.clone(),
            requester_actor_id: request.requester_actor_id.clone(),
            requester_device_id: request.requester_device_id.clone(),
            result: Some(rpc_response::Result::AddWorkspaceResult(AddWorkspaceResult {
                accepted,
                error,
                workspace,
            })),
        }
    }

    async fn handle_remove_workspace(
        &mut self,
        request: &crate::proto::teamclaw::RpcRequest,
        remove: &crate::proto::teamclaw::RemoveWorkspaceRequest,
    ) -> crate::proto::teamclaw::RpcResponse {
        use crate::proto::teamclaw::{rpc_response, RemoveWorkspaceResult, RpcResponse};

        let amux_remove = amux::RemoveWorkspace { workspace_id: remove.workspace_id.clone() };
        let (accepted, error) = self.apply_remove_workspace(&amux_remove).await;

        if accepted {
            let publisher = Publisher::new(&self.mqtt);
            let _ = publisher.publish_notify("workspaces.changed", "").await;
        }

        RpcResponse {
            request_id: request.request_id.clone(),
            success: accepted,
            error: error.clone(),
            requester_client_id: request.requester_client_id.clone(),
            requester_actor_id: request.requester_actor_id.clone(),
            requester_device_id: request.requester_device_id.clone(),
            result: Some(rpc_response::Result::RemoveWorkspaceResult(RemoveWorkspaceResult {
                accepted,
                error,
            })),
        }
    }
```

- [ ] **Step 5: Wire into dispatch**

Replace the two `not_yet_implemented` lines with calls to the new handlers.

- [ ] **Step 6: Compile + test**

```bash
cd /Volumes/openbeta/workspace/amux/daemon && set -a && source .env && set +a && cargo build 2>&1 | tail -3 && cargo test --no-fail-fast 2>&1 | grep "cargo test:" | tail -1
```

- [ ] **Step 7: Commit**

```bash
cd /Volumes/openbeta/workspace/amux && git add daemon/src/daemon/server.rs && git commit -m "$(cat <<'EOF'
feat(rpc): implement AddWorkspace and RemoveWorkspace handlers

Extract apply_add_workspace / apply_remove_workspace helpers shared with
the legacy collab path. RPC handlers publish Notify{event_type:
"workspaces.changed"} on success.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: Implement `RemoveMember`

**Files:**
- Modify: `daemon/src/daemon/server.rs`

Legacy arm at server.rs:1085. Extract `apply_remove_member` helper. RPC handler publishes `Notify { event_type: "members.changed" }`.

- [ ] **Step 1: Read existing collab arm**

```bash
sed -n '1085,1100p' /Volumes/openbeta/workspace/amux/daemon/src/daemon/server.rs
```

- [ ] **Step 2: Extract `apply_remove_member` helper**

```rust
    /// Applies a member removal. Returns (success, error_text).
    /// Caller passes `requester_is_owner` because the two callers have
    /// different ways to establish it: legacy collab path looks up the
    /// peer's role via PeerTracker; RPC path looks up the requester_actor_id
    /// through AuthManager::is_owner (or similar). Centralizing the
    /// owner-check here would require the helper to know about both paths.
    async fn apply_remove_member(
        &mut self,
        remove: &amux::RemoveMember,
        requester_is_owner: bool,
    ) -> (bool, String) {
        if !requester_is_owner {
            warn!(member_id = %remove.member_id, "remove rejected: not owner");
            return (false, "not owner".to_string());
        }
        match self.auth.remove_member(&remove.member_id) {
            Ok(true) => {
                let kicked = self.peers.remove_by_member_id(&remove.member_id);
                for p in &kicked {
                    info!(peer_id = %p.peer_id, "peer kicked");
                }
                (true, String::new())
            }
            Ok(false) => (false, format!("member not found: {}", remove.member_id)),
            Err(e) => (false, e.to_string()),
        }
    }
```

- [ ] **Step 3: Update legacy arm to call the helper**

Replace the `RemoveMember` arm (lines 1085-1098 of server.rs) with:

```rust
            amux::device_collab_command::Command::RemoveMember(remove) => {
                let is_owner = self
                    .peers
                    .get_peer(&peer_id)
                    .map(|p| p.role == amux::MemberRole::Owner)
                    .unwrap_or(false);
                let (success, _error) = self.apply_remove_member(remove, is_owner).await;
                if success {
                    let _ = publisher
                        .publish_peer_list(&self.peers.to_proto_peer_list())
                        .await;
                }
            }
```

- [ ] **Step 4: Add the RPC handler**

```rust
    async fn handle_remove_member(
        &mut self,
        request: &crate::proto::teamclaw::RpcRequest,
        remove: &crate::proto::teamclaw::RemoveMemberRequest,
    ) -> crate::proto::teamclaw::RpcResponse {
        use crate::proto::teamclaw::{rpc_response, RemoveMemberResult, RpcResponse};

        let amux_remove = amux::RemoveMember { member_id: remove.member_id.clone() };
        // RPC carries requester identity in payload; resolve is_owner via
        // AuthManager, which is the source of truth for member roles.
        let is_owner = self.auth.is_owner(&request.requester_actor_id);
        let (accepted, error) = self.apply_remove_member(&amux_remove, is_owner).await;

        if accepted {
            let publisher = Publisher::new(&self.mqtt);
            let _ = publisher.publish_notify("members.changed", "").await;
        }

        RpcResponse {
            request_id: request.request_id.clone(),
            success: accepted,
            error: error.clone(),
            requester_client_id: request.requester_client_id.clone(),
            requester_actor_id: request.requester_actor_id.clone(),
            requester_device_id: request.requester_device_id.clone(),
            result: Some(rpc_response::Result::RemoveMemberResult(RemoveMemberResult {
                accepted,
                error,
            })),
        }
    }
```

- [ ] **Step 5: Wire into dispatch + compile + test + commit**

Replace `not_yet_implemented(&request, "remove_member")` with `self.handle_remove_member(&request, r).await` (bind the payload variant).

```bash
cd /Volumes/openbeta/workspace/amux/daemon && set -a && source .env && set +a && cargo build 2>&1 | tail -3 && cargo test --no-fail-fast 2>&1 | grep "cargo test:" | tail -1
```

```bash
cd /Volumes/openbeta/workspace/amux && git add daemon/src/daemon/server.rs && git commit -m "$(cat <<'EOF'
feat(rpc): implement RemoveMember handler

Shares apply_remove_member helper with legacy collab path. Publishes
Notify{event_type: "members.changed"} on success.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: Implement `StopRuntime`

**Files:**
- Modify: `daemon/src/daemon/server.rs`

Accepted-only RPC that initiates runtime termination. Terminal state (`STOPPED`) gets published to `runtime/{id}/state` retained once termination completes, then retained cleanup fires after a short grace window (see spec "Runtime lifecycle → Publish timing" step 6, and "runtime/{runtime}/state" description: "Terminal states are retained. STOPPED retains briefly then clears.").

- [ ] **Step 1: Locate the existing agent-termination code**

```bash
grep -n "stop_agent\|terminate\|kill_agent\|remove_agent" daemon/src/agent/manager.rs daemon/src/daemon/server.rs | head -10
```

The existing path is `AcpCommand::StopAgent` handling, which routes through `AgentManager`. Find the termination call — likely `self.agents.stop(&agent_id).await` or similar.

- [ ] **Step 2: Add `handle_stop_runtime`**

```rust
    async fn handle_stop_runtime(
        &mut self,
        request: &crate::proto::teamclaw::RpcRequest,
        stop: &crate::proto::teamclaw::RuntimeStopRequest,
    ) -> crate::proto::teamclaw::RpcResponse {
        use crate::proto::teamclaw::{rpc_response, RpcResponse, RuntimeStopResult};

        let runtime_id = stop.runtime_id.clone();
        if runtime_id.is_empty() {
            return RpcResponse {
                request_id: request.request_id.clone(),
                success: false,
                error: "runtime_id required".to_string(),
                requester_client_id: request.requester_client_id.clone(),
                requester_actor_id: request.requester_actor_id.clone(),
                requester_device_id: request.requester_device_id.clone(),
                result: Some(rpc_response::Result::RuntimeStopResult(RuntimeStopResult {
                    accepted: false,
                    rejected_reason: "runtime_id required".to_string(),
                })),
            };
        }

        // Look up the runtime; if it's not currently managed, reject.
        let known = self.agents.get(&runtime_id).is_some(); // adapt to actual AgentManager API
        if !known {
            return RpcResponse {
                request_id: request.request_id.clone(),
                success: false,
                error: format!("unknown runtime_id: {}", runtime_id),
                requester_client_id: request.requester_client_id.clone(),
                requester_actor_id: request.requester_actor_id.clone(),
                requester_device_id: request.requester_device_id.clone(),
                result: Some(rpc_response::Result::RuntimeStopResult(RuntimeStopResult {
                    accepted: false,
                    rejected_reason: format!("unknown runtime_id: {}", runtime_id),
                })),
            };
        }

        // Fire-and-forget termination + terminal-state publish.
        // Acceptance reply goes back immediately; STOPPED transition is
        // observed on runtime/{id}/state.
        let runtime_id_for_task = runtime_id.clone();
        let mqtt_client = self.mqtt.clone(); // or however the publisher is obtained
        // ... spawn a task that:
        //   1. calls self.agents.stop(&runtime_id).await (await termination),
        //   2. constructs RuntimeInfo { state: STOPPED, ... } (see Phase 0),
        //   3. publishes to both agent/{id}/state and runtime/{id}/state
        //      (reuse publish_agent_state — dual-publishing is already set up
        //      from Phase 1a Task 4),
        //   4. schedules a retained-clear after, e.g., 30 seconds (or fires
        //      publisher.clear_agent_state immediately — the spec is vague;
        //      choose the simpler "publish STOPPED then clear immediately").
        //
        // If the DaemonServer ownership model makes "spawn a task with
        // self.*" awkward, keep the termination synchronous within the
        // RPC handler (accept the small latency) — the spec allows it;
        // the hard requirement is that the terminal state appears on
        // runtime/{id}/state, not that the reply is non-blocking.

        // [Implementer: choose sync vs spawned-task based on what's
        // ergonomic given DaemonServer's &mut self. If sync is cleaner,
        // just await self.agents.stop(), then publish STOPPED state,
        // then return Ok. The RPC spec says "accepted-only reply" to
        // describe the semantic (reply doesn't carry lifecycle), not to
        // mandate async execution.]

        // Placeholder inline-sync version (refine as needed):
        let stop_result = self.agents.stop(&runtime_id).await;
        if let Err(e) = stop_result {
            return RpcResponse {
                request_id: request.request_id.clone(),
                success: false,
                error: format!("stop failed: {}", e),
                requester_client_id: request.requester_client_id.clone(),
                requester_actor_id: request.requester_actor_id.clone(),
                requester_device_id: request.requester_device_id.clone(),
                result: Some(rpc_response::Result::RuntimeStopResult(RuntimeStopResult {
                    accepted: false,
                    rejected_reason: format!("stop failed: {}", e),
                })),
            };
        }

        // Build a terminal RuntimeInfo snapshot with state=STOPPED.
        let stopped_info = amux::RuntimeInfo {
            runtime_id: runtime_id.clone(),
            state: amux::RuntimeLifecycle::Stopped as i32,
            // Other fields: fill from last-known snapshot if available,
            // or leave default (zero values). Minimum acceptable: runtime_id
            // and state.
            ..Default::default()
        };

        let publisher = Publisher::new(&self.mqtt);
        let _ = publisher.publish_agent_state(&runtime_id, &stopped_info).await;
        // Clear retain after publishing STOPPED. Spec allows keeping the
        // terminal state briefly; for simplicity we clear immediately.
        let _ = publisher.clear_agent_state(&runtime_id).await;

        RpcResponse {
            request_id: request.request_id.clone(),
            success: true,
            error: String::new(),
            requester_client_id: request.requester_client_id.clone(),
            requester_actor_id: request.requester_actor_id.clone(),
            requester_device_id: request.requester_device_id.clone(),
            result: Some(rpc_response::Result::RuntimeStopResult(RuntimeStopResult {
                accepted: true,
                rejected_reason: String::new(),
            })),
        }
    }
```

**Implementer note:** Adapt `self.agents.get(...)` and `self.agents.stop(...)` to the actual `AgentManager` API — grep for `fn stop` / `fn get` / `fn remove` on `AgentManager` to find the right calls. If the termination path is more complex (e.g., requires notifying Supabase that the runtime ended, updating the SessionStore, etc.), preserve the full Phase 0 behavior as the legacy `AcpCommand::StopAgent` path does it — the RPC handler should end in the same end-state.

- [ ] **Step 3: Wire into dispatch**

Replace `not_yet_implemented(&request, "runtime_stop")` with `self.handle_stop_runtime(&request, s).await` (bind the payload variant).

- [ ] **Step 4: Compile + test**

```bash
cd /Volumes/openbeta/workspace/amux/daemon && set -a && source .env && set +a && cargo build 2>&1 | tail -3 && cargo test --no-fail-fast 2>&1 | grep "cargo test:" | tail -1
```

- [ ] **Step 5: Commit**

```bash
cd /Volumes/openbeta/workspace/amux && git add daemon/src/daemon/server.rs && git commit -m "$(cat <<'EOF'
feat(rpc): implement StopRuntime handler

Looks up runtime by id, terminates via AgentManager, publishes
RuntimeInfo{state: STOPPED} to runtime/{id}/state (dual-published via
publish_agent_state from Phase 1a), then clears the retain. Acceptance
reply goes back after the state publish so callers can observe the
terminal state immediately via the retained topic. RuntimeStart
handler stays placeholder — Phase 1c plan implements the full spawn
lifecycle state machine.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 9: Final verification

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

- [ ] **Step 4: Confirm 8 of 9 placeholders were replaced**

```bash
cd /Volumes/openbeta/workspace/amux && grep -n "not_yet_implemented\|not yet implemented" daemon/src/daemon/server.rs daemon/src/teamclaw/session_manager.rs | head -20
```
Expected: 1 hit — the `RuntimeStart` placeholder (Phase 1c scope). No others.

- [ ] **Step 5: Confirm `apply_*` helpers are shared between RPC and legacy collab paths**

```bash
cd /Volumes/openbeta/workspace/amux && grep -n "fn apply_peer_announce\|fn apply_peer_disconnect\|fn apply_add_workspace\|fn apply_remove_workspace\|fn apply_remove_member" daemon/src/daemon/server.rs
grep -n "self\.apply_" daemon/src/daemon/server.rs
```
Expected: 5 helpers defined; each called from 2 sites (legacy collab arm + new RPC handler).

- [ ] **Step 6: Commit sequence review**

```bash
cd /Volumes/openbeta/workspace/amux && git log --oneline 1216419f..HEAD
```
Expected: ~8 commits, all `feat(rpc):` or `refactor(rpc):` or `feat(mqtt):`.

- [ ] **Step 7: Working tree clean of our changes**

```bash
cd /Volumes/openbeta/workspace/amux && git status --porcelain
```
Expected: only pre-existing user state (mac/Packages unresolved conflict markers, untracked `ios/AMUXUITests/`, `scripts/run-ios.sh`).

---

## Phase 1b Complete

At this point:
- 8 of 9 Phase 0 placeholder RPC match arms replaced with real handlers (FetchPeers, FetchWorkspaces, AnnouncePeer, DisconnectPeer, AddWorkspace, RemoveWorkspace, RemoveMember, StopRuntime)
- RPC dispatch now happens at `DaemonServer` level; `SessionManager` only handles session/task-scoped methods
- Mutation handlers publish `Notify` hints on `device/{id}/notify` so Phase 2 iOS can invalidate local caches
- Legacy `DeviceCollabCommand` path and new RPC path share `apply_*` helpers — single source of truth
- `StopRuntime` publishes `RuntimeInfo { state: STOPPED }` to the retained state topic (dual-published per Phase 1a)
- `RuntimeStart` still returns `"runtime_start not yet implemented"` — Phase 1c implements it

**Next plan (Phase 1c):** implement `RuntimeStart` handler with the full runtime lifecycle state machine from the spec — `STARTING` + stage transitions (`spawning_process` → `acp_connecting` → `acp_initializing` → `creating_acp_session` → `setting_model` → `persisting`) → `ACTIVE` on success or `FAILED` with populated `error_code` / `error_message` / `failed_stage` on error. This is the first user-visible behavior change (iOS Phase 2 depends on it).

**Phase 1d (gated):** `user/{actor}/notify` publish via transactional outbox — Supabase `user_inbox` table + EMQX JWT auth prereqs must ship first.
