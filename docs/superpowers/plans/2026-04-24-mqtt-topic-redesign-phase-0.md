# MQTT Topic Redesign — Phase 0 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land all proto-level changes from the MQTT topic redesign spec (rename `agent` → `runtime` types, extend `RuntimeInfo` with lifecycle fields, add new RPC methods for absorbed collab operations, add identity fields, add `Notify` message, add `RuntimeCommandEnvelope` alongside `CommandEnvelope`), regenerate Rust + Swift bindings, and fix all downstream compile errors. **Zero behavior change** at the end of this phase — daemon still publishes/subscribes on legacy topics; iOS still reads legacy topics. This phase is pure schema + type foundation for Phase 1.

**Architecture:** Proto changes live in two files: `proto/amux.proto` (runtime/device types, ACP passthrough) and `proto/teamclaw.proto` (RPC envelope, new runtime RPC methods, notify). Rust regen is automatic via `daemon/build.rs` on `cargo build` (prost-build). Swift regen is manual via `./scripts/proto-gen-swift.sh` into `ios/Packages/AMUXCore/Sources/AMUXCore/Proto/`. After each atomic change, both daemon (`cargo build && cargo test`) and iOS (`xcodebuild`) must compile clean. Each task is a single commit that leaves both trees green.

**Tech Stack:** Protobuf 3, Rust (prost/prost-build), Swift (swift-protobuf via `protoc --swift_out`), Xcode.

**Reference:** `docs/superpowers/specs/2026-04-24-mqtt-topic-redesign-design.md` — authoritative spec. When the plan and spec disagree, spec wins; stop and update the plan.

**Out of scope for Phase 0:** Daemon-side dual-publishing (Phase 1), iOS subscription switchover (Phase 2), daemon internal module/type renames like `AgentManager` → `RuntimeManager` (Phase 4), any Supabase schema changes, `user_inbox` table, broker JWT migration.

---

## File Structure

**Proto files (edited):**
- `proto/amux.proto` — renames, `RuntimeLifecycle` enum, `RuntimeInfo` lifecycle fields, `RuntimeCommandEnvelope` (new, alongside existing `CommandEnvelope`)
- `proto/teamclaw.proto` — identity fields on `RpcRequest`/`RpcResponse`, new runtime RPC messages, absorbed collab RPC messages, `Notify` message

**Generated (auto-overwritten; DO NOT hand-edit):**
- Rust: `daemon/target/debug/build/amuxd-*/out/amux.rs` and `teamclaw.rs` (prost output)
- Swift: `ios/Packages/AMUXCore/Sources/AMUXCore/Proto/amux.pb.swift` and `teamclaw.pb.swift`

**Daemon Rust consumers (hand-fix on rename):**
- `daemon/src/proto.rs`
- `daemon/src/agent/handle.rs`, `daemon/src/agent/manager.rs`
- `daemon/src/mqtt/publisher.rs`, `daemon/src/mqtt/subscriber.rs`, `daemon/src/mqtt/client.rs`
- `daemon/src/daemon/server.rs`
- `daemon/src/cli/test_client.rs`
- `daemon/src/config/session_store.rs`
- `daemon/tests/teamclaw_mqtt_rearchitecture.rs`

**iOS Swift consumers (hand-fix on rename):**
- `ios/Packages/AMUXCore/Sources/AMUXCore/ConnectionMonitor.swift`
- `ios/Packages/AMUXCore/Sources/AMUXCore/ViewModels/AgentDetailViewModel.swift`
- `ios/Packages/AMUXCore/Sources/AMUXCore/ViewModels/SessionListViewModel.swift`
- `ios/Packages/AMUXUI/Sources/AMUXUI/Workspace/WorkspaceManagementView.swift`
- `ios/Packages/AMUXUI/Sources/AMUXUI/SessionList/NewSessionSheet.swift`
- `ios/Packages/AMUXUI/Sources/AMUXUI/Members/MemberListContent.swift`

**Unchanged in this phase:** all SwiftData `@Model` types (`Agent`, `AgentEvent` stay — renamed in Phase 2), all daemon internal types (`AgentManager`, `AgentHandle` stay — renamed in Phase 4).

---

## Task 1: Verify green baseline

**Files:** none (read-only verification)

- [ ] **Step 1: Confirm daemon builds clean**

Run:
```bash
cd /Volumes/openbeta/workspace/amux/daemon && cargo build 2>&1 | tail -5
```
Expected: `Finished \`dev\` profile` (or `dev [unoptimized + debuginfo] target`). No errors.

- [ ] **Step 2: Confirm daemon tests pass**

Run:
```bash
cd /Volumes/openbeta/workspace/amux/daemon && cargo test --no-fail-fast 2>&1 | tail -20
```
Expected: `test result: ok. N passed; 0 failed` on each test binary. If anything fails, **stop** — we need a clean baseline before changing protos.

- [ ] **Step 3: Confirm iOS builds clean**

Run:
```bash
cd /Volumes/openbeta/workspace/amux/ios && xcodebuild -project AMUX.xcodeproj -scheme AMUX -destination 'generic/platform=iOS' -configuration Debug build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`. If this fails, fix or get help before continuing — a rename cascade on top of a broken baseline is untriageable.

- [ ] **Step 4: Record current proto field-number ceilings**

Run:
```bash
grep -E "^\s*[^/]\s*= [0-9]+;" /Volumes/openbeta/workspace/amux/proto/amux.proto | grep -oE "= [0-9]+" | sort -n | tail -5
grep -E "^\s*[^/]\s*= [0-9]+;" /Volumes/openbeta/workspace/amux/proto/teamclaw.proto | grep -oE "= [0-9]+" | sort -n | tail -5
```
Note the highest field numbers already in use — **never reuse** these when adding fields. New fields always take unused numbers.

- [ ] **Step 5: Commit nothing; move to Task 2**

This task produces no diff. It establishes that the working tree is in a known-good state before we start editing protos.

---

## Task 2: Add `RuntimeLifecycle` enum to `amux.proto`

**Files:**
- Modify: `proto/amux.proto` (add enum near existing `AgentStatus`)

- [ ] **Step 1: Insert the enum in `amux.proto`**

Locate the `AgentStatus` enum (around line 354) and **after** its closing `}`, insert:

```proto
// Lifecycle state for a Claude Code runtime (subprocess).
// Published on device/{id}/runtime/{id}/state topic.
// See spec: docs/superpowers/specs/2026-04-24-mqtt-topic-redesign-design.md#runtime-lifecycle
enum RuntimeLifecycle {
  RUNTIME_LIFECYCLE_UNKNOWN = 0;
  RUNTIME_LIFECYCLE_STARTING = 1;
  RUNTIME_LIFECYCLE_ACTIVE = 2;
  RUNTIME_LIFECYCLE_FAILED = 3;
  RUNTIME_LIFECYCLE_STOPPED = 4;
}
```

Leave `AgentStatus` untouched — it's an ACP-passthrough enum and keeps its existing name.

- [ ] **Step 2: Regenerate Rust bindings**

Run:
```bash
cd /Volumes/openbeta/workspace/amux/daemon && cargo build 2>&1 | tail -5
```
Expected: Finished, no errors. Adding a new enum cannot break existing consumers.

- [ ] **Step 3: Regenerate Swift bindings**

Run:
```bash
/Volumes/openbeta/workspace/amux/scripts/proto-gen-swift.sh
```
Expected: `✓ Swift proto generated in ...`.

- [ ] **Step 4: Verify iOS still builds**

Run:
```bash
cd /Volumes/openbeta/workspace/amux/ios && xcodebuild -project AMUX.xcodeproj -scheme AMUX -destination 'generic/platform=iOS' -configuration Debug build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
cd /Volumes/openbeta/workspace/amux && git add proto/amux.proto ios/Packages/AMUXCore/Sources/AMUXCore/Proto/amux.pb.swift && git commit -m "feat(proto): add RuntimeLifecycle enum for runtime state machine"
```

---

## Task 3: Rename `AgentInfo` → `RuntimeInfo` and add lifecycle fields

**Files:**
- Modify: `proto/amux.proto` (rename message, add fields)
- Modify: all Rust files importing `AgentInfo` (see File Structure)
- Modify: all Swift files referencing `AgentInfo` (see File Structure)

- [ ] **Step 1: Edit the message in `amux.proto`**

Locate `message AgentInfo {` (around line 363). Rename to `RuntimeInfo`, rename the `agent_id` field to `runtime_id` (field number unchanged), and append lifecycle fields after existing field 13. Replace:

```proto
message AgentInfo {
  string agent_id = 1;
  AgentType agent_type = 2;
  string worktree = 3;
  string branch = 4;
  AgentStatus status = 5;
  int64 started_at = 6;
  string current_prompt = 7;
  string workspace_id = 8;
  string session_title = 9;
  string last_output_summary = 10;
  int32 tool_use_count = 11;
  repeated ModelInfo available_models = 12;
  string current_model = 13;
}
```

with:

```proto
// Payload of device/{id}/runtime/{id}/state (retained).
// See spec: docs/superpowers/specs/2026-04-24-mqtt-topic-redesign-design.md
message RuntimeInfo {
  string runtime_id = 1;
  AgentType agent_type = 2;
  string worktree = 3;
  string branch = 4;
  AgentStatus status = 5;             // ACP-level status (kept); lifecycle is separate
  int64 started_at = 6;
  string current_prompt = 7;
  string workspace_id = 8;
  string session_title = 9;
  string last_output_summary = 10;
  int32 tool_use_count = 11;
  repeated ModelInfo available_models = 12;
  string current_model = 13;

  // Lifecycle fields — see RuntimeLifecycle and Runtime lifecycle section in spec.
  RuntimeLifecycle state = 14;
  string stage = 15;                  // meaningful iff state == STARTING
  string error_code = 16;             // meaningful iff state == FAILED
  string error_message = 17;          // meaningful iff state == FAILED
  string failed_stage = 18;           // meaningful iff state == FAILED
}
```

Also rename `message AgentList` (around line 384) field `repeated AgentInfo agents = 1;` → `repeated RuntimeInfo runtimes = 1;`. The `AgentList` message name itself stays for Phase 0 (dead code to be deleted in a later phase; renaming it here expands the diff surface).

- [ ] **Step 2: Regenerate Rust bindings and list compile errors**

Run:
```bash
cd /Volumes/openbeta/workspace/amux/daemon && cargo build 2>&1 | grep -E "^error" | head -40
```
Expected: many errors of form `cannot find type AgentInfo` or `no field agent_id`. Note every file.

- [ ] **Step 3: Fix Rust consumers**

For each file reported in Step 2, replace:
- `AgentInfo` → `RuntimeInfo`
- `.agent_id` field access on what is now a `RuntimeInfo` → `.runtime_id`
- `AgentList { agents: ... }` → `AgentList { runtimes: ... }` (the wrapper type keeps its name for now)

Primary files (search and replace by careful `grep` — do NOT globally substitute `agent_id` since `Envelope.agent_id` and `CommandEnvelope.agent_id` are renamed in a separate task):

Targeted replacements in each file, using only `RuntimeInfo`:
```bash
cd /Volumes/openbeta/workspace/amux/daemon
grep -rln "AgentInfo" src/ tests/
# For each hit, edit by hand: replace AgentInfo -> RuntimeInfo, and when it's a variable of that type, its .agent_id field access -> .runtime_id
```

- [ ] **Step 4: Verify Rust compiles and tests pass**

Run:
```bash
cd /Volumes/openbeta/workspace/amux/daemon && cargo build 2>&1 | tail -5 && cargo test --no-fail-fast 2>&1 | tail -20
```
Expected: Build finishes; all tests pass.

- [ ] **Step 5: Regenerate Swift bindings**

Run:
```bash
/Volumes/openbeta/workspace/amux/scripts/proto-gen-swift.sh
```

- [ ] **Step 6: Fix Swift consumers**

Swift generated types use the form `Amux_AgentInfo` → now `Amux_RuntimeInfo`. Field `agentID` → `runtimeID` (swift-protobuf camelCases from snake_case).

```bash
cd /Volumes/openbeta/workspace/amux/ios
grep -rln "Amux_AgentInfo\|\.agentID" Packages/AMUXCore/Sources Packages/AMUXUI/Sources --include='*.swift' | grep -v .pb.swift
```
For each hit, replace:
- `Amux_AgentInfo` → `Amux_RuntimeInfo`
- `.agentID` (when referring to a `Runtime`/`Amux_RuntimeInfo`'s id) → `.runtimeID`

**Do not blindly replace `.agentID` project-wide** — the SwiftData `Agent` model has its own `agentId` / `agentID` property that stays unrenamed in this phase. Only change accesses on proto types.

- [ ] **Step 7: Verify iOS compiles**

Run:
```bash
cd /Volumes/openbeta/workspace/amux/ios && xcodebuild -project AMUX.xcodeproj -scheme AMUX -destination 'generic/platform=iOS' -configuration Debug build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 8: Commit**

```bash
cd /Volumes/openbeta/workspace/amux && git add -A proto/ daemon/ ios/Packages/AMUXCore/Sources/AMUXCore/Proto/ ios/Packages/ && git commit -m "feat(proto): rename AgentInfo -> RuntimeInfo, add lifecycle fields"
```

---

## Task 4: Rename `DeviceStatus` → `DeviceState`

**Files:**
- Modify: `proto/amux.proto`
- Modify: Rust consumers (at least `daemon/src/mqtt/client.rs` where LWT uses it)
- Modify: Swift consumers (at least `ConnectionMonitor.swift`)

- [ ] **Step 1: Edit the message in `amux.proto`**

Locate `message DeviceStatus {` (around line 327). Replace:

```proto
message DeviceStatus {
  bool online = 1;
  string device_name = 2;
  int64 timestamp = 3;
}
```

with:

```proto
// Payload of device/{id}/state (retained, LWT-backed from Phase 3 onward).
// See spec: docs/superpowers/specs/2026-04-24-mqtt-topic-redesign-design.md
message DeviceState {
  bool online = 1;
  string device_name = 2;
  int64 timestamp = 3;
}
```

- [ ] **Step 2: Regenerate Rust and identify consumers**

Run:
```bash
cd /Volumes/openbeta/workspace/amux/daemon && cargo build 2>&1 | grep -E "^error" | head -20
```
Expected: errors pointing at `DeviceStatus` usage (LWT construction in `mqtt/client.rs`, possibly others).

- [ ] **Step 3: Fix Rust consumers**

Find all references:
```bash
cd /Volumes/openbeta/workspace/amux/daemon && grep -rln "DeviceStatus" src/ tests/
```
Replace `DeviceStatus` → `DeviceState` in each. Verify each hit is a proto reference, not some unrelated identifier.

- [ ] **Step 4: Verify Rust build + tests**

```bash
cd /Volumes/openbeta/workspace/amux/daemon && cargo build 2>&1 | tail -3 && cargo test --no-fail-fast 2>&1 | tail -10
```
Expected: clean.

- [ ] **Step 5: Regenerate Swift and fix consumers**

```bash
/Volumes/openbeta/workspace/amux/scripts/proto-gen-swift.sh
cd /Volumes/openbeta/workspace/amux/ios && grep -rln "Amux_DeviceStatus" Packages --include='*.swift' | grep -v .pb.swift
```
For each hit, replace `Amux_DeviceStatus` → `Amux_DeviceState`.

- [ ] **Step 6: Verify iOS build**

```bash
cd /Volumes/openbeta/workspace/amux/ios && xcodebuild -project AMUX.xcodeproj -scheme AMUX -destination 'generic/platform=iOS' -configuration Debug build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 7: Commit**

```bash
cd /Volumes/openbeta/workspace/amux && git add -A && git commit -m "feat(proto): rename DeviceStatus -> DeviceState"
```

---

## Task 5: Rename `AgentStartResult` → `RuntimeStartResult` and its `agent_id` → `runtime_id`

**Files:**
- Modify: `proto/amux.proto`
- Modify: Rust consumers (daemon server dispatch for `DeviceCollabEvent`)
- Modify: Swift consumers

Note: the existing `AgentStartResult` is the **legacy** start result used today over `/collab`. The **new** `RuntimeStartResult` we'll add to teamclaw.proto in Task 10 is the accepted-only Phase 1 RPC result — they are different messages that happen to share a similar concept. To avoid name collision, we'll rename the legacy amux.proto message to `LegacyAgentStartResult`, freeing the `RuntimeStartResult` name for the new RPC variant in teamclaw.proto.

- [ ] **Step 1: Edit the message in `amux.proto`**

Locate `message AgentStartResult {` (around line 290). Replace the entire message:

```proto
message AgentStartResult {
  string command_id = 1;
  bool success = 2;
  string error = 3;
  string agent_id = 4;
  string session_id = 5;
}
```

with:

```proto
// Legacy start result delivered via DeviceCollabEvent on /collab topic.
// Kept during Phase 0–4 for dual-path compatibility; deleted in Phase 5 along
// with the rest of DeviceCollabEvent. The new accepted-only runtime-start
// reply is teamclaw.RuntimeStartResult (Phase 1).
message LegacyAgentStartResult {
  string command_id = 1;
  bool success = 2;
  string error = 3;
  string runtime_id = 4;              // was agent_id
  string session_id = 5;
}
```

Also locate `DeviceCollabEvent` (around line 208) and update the oneof field:

```proto
    AgentStartResult agent_start_result = 9;
```

becomes:

```proto
    LegacyAgentStartResult agent_start_result = 9;
```

(Keep the oneof **field name** `agent_start_result` — field names are wire-stable; only the message type changed.)

- [ ] **Step 2: Rebuild Rust and fix consumers**

```bash
cd /Volumes/openbeta/workspace/amux/daemon && cargo build 2>&1 | grep -E "^error" | head -20
grep -rln "AgentStartResult" src/ tests/
```
Replace `AgentStartResult` → `LegacyAgentStartResult` in each file. Field access `.agent_id` on that type → `.runtime_id`.

- [ ] **Step 3: Verify Rust build + tests**

```bash
cd /Volumes/openbeta/workspace/amux/daemon && cargo build 2>&1 | tail -3 && cargo test --no-fail-fast 2>&1 | tail -10
```

- [ ] **Step 4: Regen Swift and fix consumers**

```bash
/Volumes/openbeta/workspace/amux/scripts/proto-gen-swift.sh
cd /Volumes/openbeta/workspace/amux/ios && grep -rln "Amux_AgentStartResult" Packages --include='*.swift' | grep -v .pb.swift
```
Replace `Amux_AgentStartResult` → `Amux_LegacyAgentStartResult`. Access `.agentID` on that type → `.runtimeID`.

- [ ] **Step 5: Verify iOS build**

```bash
cd /Volumes/openbeta/workspace/amux/ios && xcodebuild -project AMUX.xcodeproj -scheme AMUX -destination 'generic/platform=iOS' -configuration Debug build 2>&1 | tail -5
```

- [ ] **Step 6: Commit**

```bash
cd /Volumes/openbeta/workspace/amux && git add -A && git commit -m "feat(proto): rename AgentStartResult -> LegacyAgentStartResult, free RuntimeStartResult namespace"
```

---

## Task 6: Rename subprocess `agent_id` → `runtime_id` on `Envelope` and `CommandEnvelope`

**Files:**
- Modify: `proto/amux.proto`
- Modify: all Rust and Swift consumers that read these field names

Be careful: **only rename** fields that reference the Claude Code subprocess. The Supabase `agents.id` FK (daemon identity) keeps its field names. Per spec: `Envelope.agent_id` and `CommandEnvelope.agent_id` are subprocess references — rename these. `Envelope.device_id` and `CommandEnvelope.device_id` are daemon references — leave untouched.

- [ ] **Step 1: Edit `Envelope` and `CommandEnvelope` in `amux.proto`**

Locate `message Envelope {` (line 9). Change field 1:
```proto
  string agent_id = 1;
```
to:
```proto
  string runtime_id = 1;
```

Locate `message CommandEnvelope {` (line 23). Change field 1 the same way:
```proto
  string agent_id = 1;
```
to:
```proto
  string runtime_id = 1;
```

**Field numbers stay identical** — this is a source-level rename only; wire format is unchanged.

- [ ] **Step 2: Rebuild Rust and find consumers**

```bash
cd /Volumes/openbeta/workspace/amux/daemon && cargo build 2>&1 | grep -E "^error" | head -40
```
Many errors expected. Consumers are patterns like `envelope.agent_id`, destructures like `IncomingMessage::AgentCommand { agent_id, .. }` (the Rust **enum variant** field is named `agent_id` because we haven't renamed that yet — that's Phase 4 — but the proto field is now `runtime_id`). For now, where the field comes from `envelope.agent_id` or `command_envelope.agent_id`, use `.runtime_id`.

Distinguishing cases:
- `let envelope: amux::Envelope = ...; envelope.agent_id` — proto field, **rename** to `envelope.runtime_id`
- `let agent_id: String = ...; ` (local binding, no proto type) — unrelated, leave alone
- `let msg = IncomingMessage::AgentCommand { agent_id, envelope }` — Rust enum variant field (Phase 4 rename); leave alone but rebind inside the block if needed: `let runtime_id = envelope.runtime_id.clone();`

Work through every compile error. Do not do a global find/replace — it will mangle unrelated `agent_id` bindings.

- [ ] **Step 3: Verify Rust build + tests**

```bash
cd /Volumes/openbeta/workspace/amux/daemon && cargo build 2>&1 | tail -3 && cargo test --no-fail-fast 2>&1 | tail -10
```

- [ ] **Step 4: Regen Swift and fix consumers**

```bash
/Volumes/openbeta/workspace/amux/scripts/proto-gen-swift.sh
```

In Swift generated code, `Envelope.agent_id` appears as `envelope.agentID`; now `envelope.runtimeID`. Find usages:
```bash
cd /Volumes/openbeta/workspace/amux/ios && grep -rln "Amux_Envelope\|Amux_CommandEnvelope" Packages --include='*.swift' | grep -v .pb.swift
```

For each file, hand-check property accesses on these two types: `.agentID` → `.runtimeID`. Again, do not global-replace — the SwiftData `Agent.agentId` is a separate property that stays.

- [ ] **Step 5: Verify iOS build**

```bash
cd /Volumes/openbeta/workspace/amux/ios && xcodebuild -project AMUX.xcodeproj -scheme AMUX -destination 'generic/platform=iOS' -configuration Debug build 2>&1 | tail -5
```

- [ ] **Step 6: Commit**

```bash
cd /Volumes/openbeta/workspace/amux && git add -A && git commit -m "feat(proto): rename Envelope.agent_id and CommandEnvelope.agent_id to runtime_id"
```

---

## Task 7: Add `RuntimeCommandEnvelope` alongside existing `CommandEnvelope`

**Files:**
- Modify: `proto/amux.proto` (new message, **no** edits to `CommandEnvelope`)

This is the only dual-existence proto rename. `CommandEnvelope` stays as-is for Phase 1 dual-publish. `RuntimeCommandEnvelope` is structurally identical but lives on the new `runtime/{id}/commands` topic.

- [ ] **Step 1: Add `RuntimeCommandEnvelope` to `amux.proto`**

Immediately after `message CommandEnvelope { ... }` (ends around line 39), insert:

```proto
// New envelope for device/{id}/runtime/{id}/commands (Phase 1+ topic).
// Structurally identical to CommandEnvelope; exists separately so both old
// and new topics can coexist during the dual-publish migration window.
// CommandEnvelope is retired in Phase 5.
message RuntimeCommandEnvelope {
  string runtime_id = 1;
  string device_id = 2;
  string peer_id = 3;
  string command_id = 4;
  int64 timestamp = 5;
  string sender_actor_id = 6;
  string reply_to_device_id = 7;

  AcpCommand acp_command = 10;
}
```

- [ ] **Step 2: Regenerate both ends**

```bash
cd /Volumes/openbeta/workspace/amux/daemon && cargo build 2>&1 | tail -3
/Volumes/openbeta/workspace/amux/scripts/proto-gen-swift.sh
cd /Volumes/openbeta/workspace/amux/ios && xcodebuild -project AMUX.xcodeproj -scheme AMUX -destination 'generic/platform=iOS' -configuration Debug build 2>&1 | tail -3
```
Expected: both pass. Adding a new message cannot break existing callers.

- [ ] **Step 3: Commit**

```bash
cd /Volumes/openbeta/workspace/amux && git add -A && git commit -m "feat(proto): add RuntimeCommandEnvelope alongside CommandEnvelope"
```

---

## Task 8: Add identity fields to `RpcRequest` and `RpcResponse`

**Files:**
- Modify: `proto/teamclaw.proto`

The three requester identity fields enable filtering on the shared `rpc/res` topic. Existing callers send empty strings (proto3 default); existing handlers ignore unknown fields harmlessly.

- [ ] **Step 1: Edit `RpcRequest` in `teamclaw.proto`**

Locate `message RpcRequest {` (around line 141). Replace:

```proto
message RpcRequest {
  string request_id = 1;
  string sender_device_id = 2;
  oneof method {
    CreateSessionRequest create_session = 10;
    JoinSessionRequest join_session = 11;
    FetchSessionRequest fetch_session = 12;
    AddParticipantRequest add_participant = 13;
    RemoveParticipantRequest remove_participant = 14;
    CreateTaskRequest create_task = 15;
    ClaimTaskRequest claim_task = 16;
    SubmitTaskRequest submit_task = 17;
    UpdateTaskRequest update_task = 18;
    FetchSessionMessagesRequest fetch_session_messages = 20;
  }
}
```

with:

```proto
message RpcRequest {
  string request_id = 1;
  string sender_device_id = 2;        // legacy; kept during migration, equivalent to requester_device_id
  // Identity fields — spec "Addressing and Identity". Receivers on the shared
  // rpc/res topic filter by whichever one is populated. Empty = not applicable.
  string requester_client_id = 3;      // iOS/mac install UUID
  string requester_actor_id = 4;       // Supabase actor id of signed-in user
  string requester_device_id = 5;      // populated when another daemon is the caller
  oneof method {
    CreateSessionRequest create_session = 10;
    JoinSessionRequest join_session = 11;
    FetchSessionRequest fetch_session = 12;
    AddParticipantRequest add_participant = 13;
    RemoveParticipantRequest remove_participant = 14;
    CreateTaskRequest create_task = 15;
    ClaimTaskRequest claim_task = 16;
    SubmitTaskRequest submit_task = 17;
    UpdateTaskRequest update_task = 18;
    FetchSessionMessagesRequest fetch_session_messages = 20;
  }
}
```

- [ ] **Step 2: Edit `RpcResponse` in `teamclaw.proto`**

Locate `message RpcResponse {` (around line 158). Replace:

```proto
message RpcResponse {
  string request_id = 1;
  bool success = 2;
  string error = 3;
  oneof result {
    SessionInfo session_info = 10;
    Task task = 11;
    Claim claim = 12;
    Submission submission = 13;
    SessionMessagePage session_message_page = 14;
  }
}
```

with:

```proto
message RpcResponse {
  string request_id = 1;
  bool success = 2;
  string error = 3;
  // Copy-through identity fields from RpcRequest, so any subscriber on the
  // shared rpc/res topic can filter cheaply by whichever id they authored with.
  string requester_client_id = 4;
  string requester_actor_id = 5;
  string requester_device_id = 6;
  oneof result {
    SessionInfo session_info = 10;
    Task task = 11;
    Claim claim = 12;
    Submission submission = 13;
    SessionMessagePage session_message_page = 14;
  }
}
```

- [ ] **Step 3: Regenerate both ends**

```bash
cd /Volumes/openbeta/workspace/amux/daemon && cargo build 2>&1 | tail -5
/Volumes/openbeta/workspace/amux/scripts/proto-gen-swift.sh
cd /Volumes/openbeta/workspace/amux/ios && xcodebuild -project AMUX.xcodeproj -scheme AMUX -destination 'generic/platform=iOS' -configuration Debug build 2>&1 | tail -3
```
Expected: both pass. Existing call sites that construct `RpcRequest { request_id, sender_device_id, method: Some(...) }` still work because the new fields default to empty.

- [ ] **Step 4: Run tests**

```bash
cd /Volumes/openbeta/workspace/amux/daemon && cargo test --no-fail-fast 2>&1 | tail -10
```

- [ ] **Step 5: Commit**

```bash
cd /Volumes/openbeta/workspace/amux && git add -A && git commit -m "feat(proto): add requester identity fields to RpcRequest/RpcResponse"
```

---

## Task 9: Add `RuntimeStartRequest` / `RuntimeStartResult` messages

**Files:**
- Modify: `proto/teamclaw.proto`

This is the new accepted-only runtime-spawn RPC. Replaces the legacy `/collab`-based start path that used `AcpStartAgent` + `LegacyAgentStartResult`.

- [ ] **Step 1: Add the two messages to `teamclaw.proto`**

Append to the end of `teamclaw.proto` (after `UpdateTaskRequest`):

```proto
// ═══════════════════════════════════════════
//  Runtime lifecycle RPCs
// ═══════════════════════════════════════════

// Request the daemon spawn a new Claude Code subprocess.
// Accepted-only reply — actual lifecycle flows on device/{id}/runtime/{id}/state.
// See spec "Runtime lifecycle" section for the state machine.
message RuntimeStartRequest {
  amux.AgentType agent_type = 1;        // required
  string initial_prompt = 2;            // optional — first user message at spawn
  string model_id = 3;                  // optional — empty = daemon default

  // All three below are OPTIONAL; empty = bare-agent spawn.
  string workspace_id = 4;              // empty = no workspace binding
  string worktree = 5;                  // empty = daemon picks default working directory
  string session_id = 6;                // empty = no Supabase sessions.id linkage
}

// Accepted-only reply to RuntimeStartRequest.
// DOES NOT include RuntimeInfo. Readiness flows on the retained state topic.
message RuntimeStartResult {
  bool accepted = 1;
  string runtime_id = 2;                // allocated by daemon; present iff accepted
  string session_id = 3;                // echoed or newly-created; empty for bare-agent spawn
  string rejected_reason = 4;           // set iff !accepted (validation / auth / resource error)
}
```

Note the `amux.AgentType` reference — this imports from amux.proto. Add the import at the top of `teamclaw.proto` if it is not already there.

- [ ] **Step 2: Add proto import at top of `teamclaw.proto`**

If not already present (check first with `head -5 /Volumes/openbeta/workspace/amux/proto/teamclaw.proto`), insert **after** the `package teamclaw;` line:

```proto
import "amux.proto";
```

- [ ] **Step 3: Wire new messages into `RpcRequest` and `RpcResponse` oneofs**

In `RpcRequest.method` oneof, add after `fetch_session_messages = 20;`:
```proto
    RuntimeStartRequest runtime_start = 30;
```

In `RpcResponse.result` oneof, add after `session_message_page = 14;`:
```proto
    RuntimeStartResult runtime_start_result = 20;
```

Pick field numbers that don't collide with existing entries. Use the ceiling you noted in Task 1 Step 4; 30 and 20 above are chosen to leave room for future additions in the 15-19 range within RpcResponse if needed.

- [ ] **Step 4: Regenerate and verify**

```bash
cd /Volumes/openbeta/workspace/amux/daemon && cargo build 2>&1 | tail -5
/Volumes/openbeta/workspace/amux/scripts/proto-gen-swift.sh
cd /Volumes/openbeta/workspace/amux/ios && xcodebuild -project AMUX.xcodeproj -scheme AMUX -destination 'generic/platform=iOS' -configuration Debug build 2>&1 | tail -3
```
Expected: both pass. Existing consumers compile because the oneof match arms don't need new cases until Phase 1 handlers are written.

- [ ] **Step 5: Commit**

```bash
cd /Volumes/openbeta/workspace/amux && git add -A && git commit -m "feat(proto): add RuntimeStartRequest/Result with accepted-only reply shape"
```

---

## Task 10: Add `RuntimeStopRequest` / `RuntimeStopResult`

**Files:**
- Modify: `proto/teamclaw.proto`

- [ ] **Step 1: Add the two messages to `teamclaw.proto`**

Append after `RuntimeStartResult`:

```proto
// Request a runtime terminate. Accepted-only reply.
// Actual termination observable as state: STOPPED on runtime/{id}/state.
message RuntimeStopRequest {
  string runtime_id = 1;
}

message RuntimeStopResult {
  bool accepted = 1;
  string rejected_reason = 2;           // set iff !accepted
}
```

- [ ] **Step 2: Wire into oneofs**

In `RpcRequest.method`, after `runtime_start = 30;`:
```proto
    RuntimeStopRequest runtime_stop = 31;
```

In `RpcResponse.result`, after `runtime_start_result = 20;`:
```proto
    RuntimeStopResult runtime_stop_result = 21;
```

- [ ] **Step 3: Regen + verify**

```bash
cd /Volumes/openbeta/workspace/amux/daemon && cargo build 2>&1 | tail -3
/Volumes/openbeta/workspace/amux/scripts/proto-gen-swift.sh
cd /Volumes/openbeta/workspace/amux/ios && xcodebuild -project AMUX.xcodeproj -scheme AMUX -destination 'generic/platform=iOS' -configuration Debug build 2>&1 | tail -3
```
Expected: both pass.

- [ ] **Step 4: Commit**

```bash
cd /Volumes/openbeta/workspace/amux && git add -A && git commit -m "feat(proto): add RuntimeStopRequest/Result"
```

---

## Task 11: Add absorbed collab-op RPC messages and wire into oneofs

**Files:**
- Modify: `proto/teamclaw.proto`

Each of today's `DeviceCollabCommand` variants becomes a dedicated `RpcRequest` method. The legacy amux.proto messages (`PeerAnnounce`, `PeerDisconnect`, `RemoveMember`, `AddWorkspace`, `RemoveWorkspace`) stay in place (still used by `DeviceCollabCommand` during Phase 1); we define parallel `*Request`/`*Result` messages in teamclaw.proto.

- [ ] **Step 1: Add the messages to `teamclaw.proto`**

Append after `RuntimeStopResult`:

```proto
// ═══════════════════════════════════════════
//  Absorbed collab operations
//  (parallel to amux.DeviceCollabCommand variants; the legacy path is
//   retired in Phase 5)
// ═══════════════════════════════════════════

message AnnouncePeerRequest {
  amux.PeerInfo peer = 1;
  string auth_token = 2;
}

message AnnouncePeerResult {
  bool accepted = 1;
  string error = 2;
  amux.MemberRole assigned_role = 3;
}

message DisconnectPeerRequest {
  string peer_id = 1;
}

message DisconnectPeerResult {
  bool accepted = 1;
  string error = 2;
}

message RemoveMemberRequest {
  string member_id = 1;
}

message RemoveMemberResult {
  bool accepted = 1;
  string error = 2;
}

message AddWorkspaceRequest {
  string path = 1;
}

message AddWorkspaceResult {
  bool accepted = 1;
  string error = 2;
  amux.WorkspaceInfo workspace = 3;
}

message RemoveWorkspaceRequest {
  string workspace_id = 1;
}

message RemoveWorkspaceResult {
  bool accepted = 1;
  string error = 2;
}

message FetchPeersRequest {}

message FetchPeersResult {
  repeated amux.PeerInfo peers = 1;
}

message FetchWorkspacesRequest {}

message FetchWorkspacesResult {
  repeated amux.WorkspaceInfo workspaces = 1;
}
```

- [ ] **Step 2: Wire requests into `RpcRequest.method` oneof**

After `runtime_stop = 31;`:
```proto
    AnnouncePeerRequest announce_peer = 40;
    DisconnectPeerRequest disconnect_peer = 41;
    RemoveMemberRequest remove_member = 42;
    AddWorkspaceRequest add_workspace = 43;
    RemoveWorkspaceRequest remove_workspace = 44;
    FetchPeersRequest fetch_peers = 45;
    FetchWorkspacesRequest fetch_workspaces = 46;
```

- [ ] **Step 3: Wire results into `RpcResponse.result` oneof**

After `runtime_stop_result = 21;`:
```proto
    AnnouncePeerResult announce_peer_result = 30;
    DisconnectPeerResult disconnect_peer_result = 31;
    RemoveMemberResult remove_member_result = 32;
    AddWorkspaceResult add_workspace_result = 33;
    RemoveWorkspaceResult remove_workspace_result = 34;
    FetchPeersResult fetch_peers_result = 35;
    FetchWorkspacesResult fetch_workspaces_result = 36;
```

- [ ] **Step 4: Regen + verify**

```bash
cd /Volumes/openbeta/workspace/amux/daemon && cargo build 2>&1 | tail -3
/Volumes/openbeta/workspace/amux/scripts/proto-gen-swift.sh
cd /Volumes/openbeta/workspace/amux/ios && xcodebuild -project AMUX.xcodeproj -scheme AMUX -destination 'generic/platform=iOS' -configuration Debug build 2>&1 | tail -3
```

- [ ] **Step 5: Commit**

```bash
cd /Volumes/openbeta/workspace/amux && git add -A && git commit -m "feat(proto): add absorbed collab-op RPC messages (announce/disconnect/member/workspace/fetch)"
```

---

## Task 12: Add `Notify` message

**Files:**
- Modify: `proto/teamclaw.proto`

Note: there is already a `NotifyEnvelope` message in teamclaw.proto (line 130). That is the **legacy** notify shape with `target_device_id` and `session_id` fields. The spec's new `Notify` is a hint-only payload shared between `device/{id}/notify` and `user/{actor}/notify`. Add `Notify` as a new message; leave `NotifyEnvelope` alone for Phase 0.

- [ ] **Step 1: Add `Notify` to `teamclaw.proto`**

Append after the last oneof wiring from Task 11:

```proto
// ═══════════════════════════════════════════
//  Notify — shared payload for device/notify and user/notify
// ═══════════════════════════════════════════

// Hint-only invalidation payload. See spec "New envelope" + "device/notify vs
// user/notify scoping". Receivers route by event_type, not by message type.
// Authoritative data lives in Supabase (or daemon RPC for peers).
message Notify {
  string event_type = 1;                // e.g. "peers.changed", "invite.received"
  string refresh_hint = 2;              // optional resource id ("session/abc")
  int64 sent_at = 3;
}
```

- [ ] **Step 2: Regen + verify**

```bash
cd /Volumes/openbeta/workspace/amux/daemon && cargo build 2>&1 | tail -3
/Volumes/openbeta/workspace/amux/scripts/proto-gen-swift.sh
cd /Volumes/openbeta/workspace/amux/ios && xcodebuild -project AMUX.xcodeproj -scheme AMUX -destination 'generic/platform=iOS' -configuration Debug build 2>&1 | tail -3
```

- [ ] **Step 3: Commit**

```bash
cd /Volumes/openbeta/workspace/amux && git add -A && git commit -m "feat(proto): add Notify message for device and user invalidation"
```

---

## Task 13: Final verification pass

**Files:** none (verification only)

- [ ] **Step 1: Full daemon build from clean**

```bash
cd /Volumes/openbeta/workspace/amux/daemon && cargo clean && cargo build 2>&1 | tail -5
```
Expected: `Finished \`dev\` profile` — full rebuild confirms no stale artifacts hide errors.

- [ ] **Step 2: Full daemon test suite**

```bash
cd /Volumes/openbeta/workspace/amux/daemon && cargo test --no-fail-fast 2>&1 | tail -30
```
Expected: every test binary reports `test result: ok. N passed; 0 failed; 0 ignored`. If any fail, stop and triage — the failure is from the rename cascade, not a pre-existing bug (we confirmed baseline green in Task 1).

- [ ] **Step 3: Full iOS build from clean**

```bash
cd /Volumes/openbeta/workspace/amux/ios && xcodebuild -project AMUX.xcodeproj -scheme AMUX -destination 'generic/platform=iOS' -configuration Debug clean build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Launch daemon briefly to verify proto round-trip**

```bash
cd /Volumes/openbeta/workspace/amux/daemon && timeout 10s cargo run -- start 2>&1 | head -30
```
Expected: daemon starts, connects to MQTT, publishes initial state, then the timeout kills it. No proto decode/encode panics. Look for any `prost::DecodeError` or `EncodeError` in output — if present, a rename missed a consumer.

- [ ] **Step 5: Diff vs. baseline — confirm behavior invariance**

```bash
cd /Volumes/openbeta/workspace/amux && git log --oneline <baseline-sha>..HEAD
```

Expected: N commits, all `feat(proto): ...`. No behavioral commits (no topic changes, no subscription changes, no publish changes). If you see behavioral commits, they belong in Phase 1 — split them out.

- [ ] **Step 6: Grep for Phase 0 completeness**

Confirm all rename targets are renamed:
```bash
cd /Volumes/openbeta/workspace/amux
grep -n "message AgentInfo\|message DeviceStatus\|message AgentStartResult" proto/amux.proto
```
Expected: **no matches**. The only legacy survivors are `AgentStatus` (ACP enum, kept), `AcpCommand` (ACP, kept), `AgentType` (enum, kept), `AgentList` (wrapper name only — Phase 4 or later), and `LegacyAgentStartResult` (explicit rename with `Legacy` prefix).

Confirm new messages exist:
```bash
grep -n "message RuntimeInfo\|message DeviceState\|message RuntimeCommandEnvelope\|message LegacyAgentStartResult\|enum RuntimeLifecycle" proto/amux.proto
grep -n "message RuntimeStartRequest\|message RuntimeStartResult\|message RuntimeStopRequest\|message Notify\|message AnnouncePeerRequest\|message FetchPeersRequest" proto/teamclaw.proto
```
Expected: every name present.

- [ ] **Step 7: No untracked files**

```bash
cd /Volumes/openbeta/workspace/amux && git status --porcelain
```
Expected: empty output. If anything is untracked (forgotten `.pb.swift` or rogue edit), stage and amend-to or add a follow-up cleanup commit.

- [ ] **Step 8: Final commit (only if Step 7 was non-empty)**

Only if verification surfaced straggler changes:
```bash
cd /Volumes/openbeta/workspace/amux && git add -A && git commit -m "chore(proto): Phase 0 verification cleanup"
```

Otherwise no commit — we're done.

---

## Phase 0 Complete

At this point:
- All proto renames from the spec's "rename in place" list have landed
- `RuntimeInfo` carries the full lifecycle schema (`state`, `stage`, `error_*`)
- `RpcRequest`/`RpcResponse` carry the three requester identity fields
- New runtime-lifecycle RPC methods (`RuntimeStart`, `RuntimeStop`) exist
- Absorbed collab-op RPC methods (`AnnouncePeer`, `DisconnectPeer`, `RemoveMember`, `AddWorkspace`, `RemoveWorkspace`, `FetchPeers`, `FetchWorkspaces`) exist
- `Notify` message exists
- `RuntimeCommandEnvelope` exists alongside `CommandEnvelope` (dual-existence)
- Both daemon and iOS compile and test clean
- **No wire-format behavior has changed** — Phase 1 is where daemon starts publishing/subscribing on new topics

**Next phase:** `docs/superpowers/plans/2026-04-XX-mqtt-topic-redesign-phase-1.md` (to be written after Phase 0 ships).
