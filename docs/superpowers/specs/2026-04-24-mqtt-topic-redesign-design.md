# MQTT Topic Redesign — Design Spec

**Status**: draft
**Date**: 2026-04-24
**Scope**: daemon MQTT topic module, iOS `MQTTTopics`, wire-format paths, proto message renames, daemon/iOS internal type renames
**Related prior work**: `2026-04-23-teamclaw-mqtt-rearchitecture-design.md`

## Goal

Consolidate AMUX's MQTT topic surface into a single consistent model. Eliminate the remaining inconsistencies left after the Teamclaw rearchitecture:

- two parallel topic modules (`Topics` and `TeamclawTopics`) with overlapping `device/{id}/...` prefixes
- naming mismatch between wire paths (`agent/{id}`) and Supabase schema (`agent_runtimes`)
- three command channels (`collab`, `runtime commands`, `rpc/req`) with three different response patterns
- retained topics that act as state stores for data that lives authoritatively in Supabase (`peers`, `workspaces`)
- leaf-name inconsistency (`status` vs `state`)
- ad-hoc string matching in `subscriber.rs` dispatch
- no user-scoped inbox for cross-daemon delivery

This is a coordinated wire-format and code change. Dual-write migration across 5 phases.

## Non-Goals

- Changing Supabase schema (table/column names stay)
- Redesigning the Teamclaw realtime contract; `session/{id}/live` + `notify` semantics from the prior spec are preserved
- Replacing ACP protocol names (`AcpEvent`, `AcpCommand` stay — they are external protocol names)
- Re-scoping what MQTT carries vs what Supabase carries

## Problem

The Teamclaw rearchitecture established a clean signaling model for session realtime, but the device/runtime layer still carries older conventions:

1. **Two topic modules.** `daemon/src/mqtt/topics.rs::Topics` owns device/runtime topics. `daemon/src/teamclaw/topics.rs::TeamclawTopics` owns Teamclaw RPC/notify/session topics. Both produce strings under `amux/{team}/device/{id}/...` — splitting them by module hides that they share a namespace.

2. **`agent` vs `runtime` naming trap.** The wire path `device/{id}/agent/{id}/state` uses "agent" to mean a Claude Code subprocess. In Supabase, `agents` = daemon, and subprocesses live in `agent_runtimes`. Every reader has to mentally translate. Documented as a known gotcha in `CLAUDE.md`.

3. **Three command channels, three response patterns.**
   - `device/{id}/collab` — event-sourced replies back on `/collab`
   - `device/{id}/agent/{id}/commands` — replies as events on `/events`
   - `device/{id}/rpc/req` — strict request/response with `request_id` correlation on `/rpc/res`
   `collab` is structurally a device-scoped RPC in disguise.

4. **Retained state stores.** `device/{id}/peers` and `device/{id}/workspaces` retain list indexes that Supabase already owns. Same anti-pattern the Teamclaw rearchitecture removed from `team/sessions`.

5. **`status` vs `state`.** Device online/offline uses `status`; runtime uses `state`. No semantic reason for the split.

6. **Subscriber dispatch is ad hoc.** `daemon/src/mqtt/subscriber.rs` mixes `.starts_with` / `.ends_with` / index-based parsing across four blocks. Adding a topic means pattern-matching in multiple places.

7. **No user-scoped inbox.** Cross-user invites currently require the recipient's daemon to be online. There is no path for "notify user X regardless of which daemon they are paired with."

## Design Principles

- **Scope pairs.** Every scope segment in a topic path comes with an id: `(device, {id})`, `(runtime, {id})`, `(session, {id})`, `(user, {id})`. Leaves are always terminal.
- **Leaf semantics are fixed and uniform.**
  - `state` — retained current snapshot (single value)
  - `events` — ephemeral out-stream
  - `commands` — ephemeral in-stream (fire-and-forget; daemon may emit events)
  - `req` / `res` — strict RPC pair (correlated by payload `request_id`)
  - `notify` — targeted invalidation hint ("refresh and re-fetch")
  - `live` — session realtime stream
  - `inbox` — user-scoped cross-daemon delivery
- **Retain only runtime-local snapshots.** `device/{id}/state` (LWT) and `runtime/{id}/state` are the only retained topics. Anything with a Supabase authoritative source is not retained.
- **Two command paths, by ownership.** Device-level operations go through `rpc/req|res`. Runtime-level ACP interaction goes through `runtime/{id}/commands` + `runtime/{id}/events`.
- **Wire terminology matches Supabase.** Daemon = `device` segment. Claude Code subprocess = `runtime` segment.

## Topic Model

```
# Retained
amux/{team}/device/{device}/state
amux/{team}/device/{device}/runtime/{runtime}/state

# Ephemeral streams
amux/{team}/device/{device}/runtime/{runtime}/events
amux/{team}/session/{session}/live

# Command / response
amux/{team}/device/{device}/runtime/{runtime}/commands
amux/{team}/device/{device}/rpc/req
amux/{team}/device/{device}/rpc/res

# Targeted invalidation
amux/{team}/device/{device}/notify
amux/{team}/user/{actor}/inbox
```

9 topic patterns, down from 11 active + 7 legacy placeholders.

### Topic details

**`device/{device}/state`** (retained, LWT)
- Replaces `device/{device}/status`
- Payload: `DeviceState { online: bool, version: string, started_at: timestamp }`
- LWT publishes `online: false` on disconnect
- iOS `ConnectionMonitor` subscribes

**`device/{device}/runtime/{runtime}/state`** (retained)
- Replaces `device/{device}/agent/{agent}/state`
- Payload: `RuntimeInfo` (renamed from `AgentInfo`)
- Cleared on runtime termination (retained empty payload)
- iOS subscribes via `device/{device}/runtime/+/state` wildcard (scoped to the paired daemon) and aggregates locally

**`device/{device}/runtime/{runtime}/events`** (ephemeral)
- Replaces `device/{device}/agent/{agent}/events`
- Payload: `AcpEvent` envelope (ACP protocol names preserved)
- Foreground iOS `RuntimeDetailViewModel` subscribes per open runtime

**`session/{session}/live`** (ephemeral)
- Unchanged from Teamclaw rearchitecture
- Payload contract documented in `2026-04-23-teamclaw-mqtt-rearchitecture-design.md`

**`device/{device}/runtime/{runtime}/commands`** (ephemeral)
- Replaces `device/{device}/agent/{agent}/commands`
- Payload: `RuntimeCommandEnvelope` (renamed from `CommandEnvelope`) with `AcpCommand` oneof
- Daemon subscribes via `device/{device}/runtime/+/commands` wildcard (its own device only)

**`device/{device}/rpc/req`** and **`device/{device}/rpc/res`** (ephemeral)
- Unchanged path from Teamclaw rearchitecture
- Payload surface expands: also carries the operations formerly on `/collab` (add/remove workspace, announce peer, add/remove member, start runtime, etc.)
- Legacy `/collab` topic removed entirely

**`device/{device}/notify`** (ephemeral)
- Unchanged from Teamclaw rearchitecture
- Scope: daemon-targeted invalidation
- Expanded to cover peers/workspaces refresh triggers (replacing those retained topics)

**`user/{actor}/inbox`** (ephemeral, new)
- User-scoped cross-daemon delivery
- Use cases: "Alice invited you to session X", membership change broadcasts, messages that must reach the user even when their daemon is offline
- All iOS clients logged in as `actor` subscribe, regardless of paired daemon
- Payload: `InboxEvent` envelope (event_id, event_type, actor_id, sent_at, body)

### `notify` vs `inbox` boundary

| Concern | `device/{id}/notify` | `user/{actor}/inbox` |
|---|---|---|
| Target | A daemon instance | A person, across all their devices |
| Semantics | "refresh your local state" | "something happened that you need to see" |
| Example | "your peer list changed — re-fetch" | "Alice invited you to session X" |
| Who subscribes | Daemon; iOS paired with that daemon | iOS clients logged in as this actor |
| Depends on daemon online | Yes | No |

### Removed topics

| Topic | Replacement |
|---|---|
| `device/{id}/status` | `device/{id}/state` (renamed, retained, LWT) |
| `device/{id}/peers` | RPC `FetchPeers` + `device/{id}/notify` on change |
| `device/{id}/workspaces` | RPC `FetchWorkspaces` + `device/{id}/notify` on change |
| `device/{id}/collab` | Split: requests on `rpc/req`, broadcasts on `notify` or `user/{actor}/inbox` |
| `device/{id}/agent/{id}/*` | `device/{id}/runtime/{id}/*` (renamed) |
| Legacy `MQTTTopics.swift` methods (`sessions`, `members`, `messages`, `tasks`, `presence`, `actor-meta`, per-request rpc) | Already unused; delete the dead code |

## Proto Changes

### Renamed messages (`proto/amux.proto`)

| Old | New | Notes |
|---|---|---|
| `AgentInfo` | `RuntimeInfo` | Payload of `runtime/{id}/state` |
| `AgentStartResult` | `RuntimeStartResult` | RPC result variant |
| `AgentStartRequest` | `RuntimeStartRequest` | RPC request variant |
| `AgentCommand` | `RuntimeCommand` | `runtime/{id}/commands` payload oneof |
| `CommandEnvelope` | `RuntimeCommandEnvelope` | Disambiguate from device-level envelopes |
| `AcpEvent` | (unchanged) | ACP is an external protocol name |
| `AcpCommand` | (unchanged) | Same |

### Deleted messages

| Message | Reason |
|---|---|
| `DeviceCommandEnvelope` | Folded into RPC request payload types |
| `DeviceCollabEvent` | Split: sync results → RPC response; async broadcasts → `notify` or `inbox` |
| `DeviceCollabCommand` | Each variant becomes an RPC method variant |

### Renamed fields

- All `agent_id` fields naming a Claude Code subprocess → `runtime_id`
- Supabase foreign-key fields that truly reference `agents.id` (daemon identity) keep the `agent_id` name — they point at Supabase's `agents` table

### New RPC methods (to replace `DeviceCollabCommand` variants)

Added to `RpcRequest.method` oneof:
- `AnnouncePeerRequest` (was `PeerAnnounce`)
- `DisconnectPeerRequest` (was `PeerDisconnect`)
- `RemoveMemberRequest` (was `RemoveMember`)
- `AddWorkspaceRequest` (was `AddWorkspace`)
- `RemoveWorkspaceRequest` (was `RemoveWorkspace`)
- `FetchPeersRequest` (new — replaces retained `peers` topic)
- `FetchWorkspacesRequest` (new — replaces retained `workspaces` topic)

Corresponding result variants added to `RpcResponse.result`.

### New envelope

- `InboxEvent` — payload for `user/{actor}/inbox`
  ```
  event_id: string
  event_type: string   // "invite.received" | "membership.changed" | ...
  actor_id: string
  sent_at: int64
  body: bytes          // event-type-specific payload
  ```

## Daemon Code Changes

### Module restructure

```
daemon/src/
├── runtime/                   # was agent/
│   ├── adapter.rs
│   └── manager.rs
├── collab/                    # DELETED — logic redistributed
├── mqtt/
│   ├── topics.rs              # absorbs teamclaw/topics.rs
│   ├── subscriber.rs          # table-driven classify()
│   └── publisher.rs
└── teamclaw/
    ├── rpc.rs                 # handles absorbed collab operations
    └── topics.rs              # DELETED — folded into mqtt/topics.rs
```

### Type renames

| Old | New |
|---|---|
| `AgentManager` | `RuntimeManager` |
| `AgentHandle` | `RuntimeHandle` |
| `AgentHandle.agent_id` | `RuntimeHandle.runtime_id` |
| `Topics` | `Topics` (unchanged name, but methods renamed and module merged) |
| `TeamclawTopics` | deleted — methods move to `Topics` |

### Unified `Topics` API

```rust
pub struct Topics {
    team_id: String,
    device_id: String,
}

impl Topics {
    // Device-scoped
    pub fn device_state(&self) -> String;
    pub fn device_notify(&self) -> String;
    pub fn device_rpc_req(&self) -> String;
    pub fn device_rpc_res(&self) -> String;

    // Runtime-scoped (under this device)
    pub fn runtime_state(&self, runtime_id: &str) -> String;
    pub fn runtime_events(&self, runtime_id: &str) -> String;
    pub fn runtime_commands(&self, runtime_id: &str) -> String;
    pub fn runtime_state_wildcard(&self) -> String;
    pub fn runtime_commands_wildcard(&self) -> String;

    // Team-scoped
    pub fn session_live(&self, session_id: &str) -> String;
    pub fn user_inbox(&self, actor_id: &str) -> String;
}
```

### Subscriber dispatch

Replace string-pattern matching with a single classifier:

```rust
pub enum TopicShape {
    DeviceState,
    DeviceNotify,
    DeviceRpcReq,
    DeviceRpcRes,
    RuntimeState   { runtime_id: String },
    RuntimeEvents  { runtime_id: String },
    RuntimeCommands{ runtime_id: String },
    SessionLive    { session_id: String },
    UserInbox      { actor_id: String },
}

pub struct TopicSegments {
    pub team_id: String,
    pub device_id: Option<String>,
}

pub fn classify(topic: &str) -> Option<(TopicShape, TopicSegments)>;
```

One function, exhaustive match in callers, one unit test per shape.

## iOS Code Changes

### SwiftData model renames

| Old | New |
|---|---|
| `Agent` (`@Model`) | `Runtime` |
| `AgentEvent` | `RuntimeEvent` |
| `Agent.agentId` | `Runtime.runtimeId` |

Requires a SwiftData schema migration (bump schema version). All relationships and persisted data migrate from `Agent` to `Runtime`.

### ViewModel / view renames

| Old | New |
|---|---|
| `AgentDetailViewModel` | `RuntimeDetailViewModel` |
| `AgentDetailView` | `RuntimeDetailView` |
| `AgentListViewModel` / similar | `RuntimeListViewModel` |

### `MQTTTopics.swift`

Renamed methods:
- `agentState` → `runtimeState`
- `agentStateWildcard` → `runtimeStateWildcard`
- `agentStatePrefix` → `runtimeStatePrefix`
- `agentEvents` → `runtimeEvents`
- `agentCommands` → `runtimeCommands`
- `deviceStatus` → `deviceState`

Deleted methods:
- `devicePeers`, `deviceWorkspaces` — replaced by RPC
- All legacy placeholders: `sessions`, `members`, session `messages` / `tasks` / `presence`, `actor-meta`, per-request RPC

New method:
- `userInbox(teamID:, actorID:)` → `amux/{team}/user/{actor}/inbox`

### Subscription changes

| Component | Change |
|---|---|
| `TeamclawService` startup | Add `userInbox` subscription for the logged-in actor. Remove `devicePeers`, `deviceWorkspaces` subscriptions. |
| `ConnectionMonitor` | Subscribe to `deviceState` (renamed from `deviceStatus`) |
| `SessionListViewModel` | Stop reading retained `workspaces`; call RPC `FetchWorkspaces` on cold start; refresh on `notify` hint |
| `RuntimeListViewModel` | Unchanged shape; subscribe to `runtime/+/state` wildcard |

## Migration Plan

Five phases. Phases 1–3 maintain dual-path compatibility so mixed-version clients work.

### Phase 0: proto rename, both-sides compile

- Edit `proto/amux.proto` to add new message types alongside old ones
  - `RuntimeInfo` added alongside `AgentInfo` (temporary duplication)
  - `RuntimeCommandEnvelope` alongside `CommandEnvelope`
  - New RPC request/result variants added to existing `RpcRequest`/`RpcResponse`
  - `InboxEvent` added
- Regenerate Rust + Swift proto code
- Both ends compile; no wire-format change yet

### Phase 1: daemon dual-publishes and dual-subscribes

- Merge `TeamclawTopics` into `Topics`; rename old methods in `Topics`
- Daemon publishes to **both** old and new paths for overlapping topics:
  - Publish `AgentInfo` on `device/{id}/agent/{id}/state` **and** `RuntimeInfo` on `device/{id}/runtime/{id}/state`
  - Publish events on both `agent/{id}/events` and `runtime/{id}/events`
  - Publish `device/{id}/status` **and** `device/{id}/state`
- Daemon subscribes to **both** old and new command paths:
  - `agent/+/commands` and `runtime/+/commands`
  - `collab` still accepted; new `rpc/req` accepts absorbed collab operations
- Daemon starts publishing to `user/{actor}/inbox` for invite/membership events
- Peers/workspaces: daemon still publishes retained topics AND answers new `FetchPeers`/`FetchWorkspaces` RPCs AND emits `notify` on change

### Phase 2: iOS switches to new paths

- `MQTTTopics.swift` updated; all call sites point to new paths
- SwiftData schema migration (`Agent` → `Runtime`)
- iOS publishes commands on `runtime/{id}/commands` and `rpc/req` (absorbed collab operations)
- iOS subscribes to `runtime/+/state`, `runtime/{id}/events`, `device/{id}/state`, `device/{id}/notify`, `device/{id}/rpc/res`, `user/{actor}/inbox`, `session/{id}/live` (per foreground session)
- iOS stops reading retained `peers` / `workspaces`; uses RPC + notify
- Legacy `MQTTTopics.swift` methods deleted
- iOS release ships

### Phase 3: daemon stops old paths

- Daemon stops publishing to `agent/{id}/state`, `agent/{id}/events`, `device/{id}/status`, `device/{id}/peers`, `device/{id}/workspaces`, `device/{id}/collab`
- Daemon stops subscribing to `agent/+/commands`, `collab`
- Daemon removes `/collab` topic constants from `Topics`
- Retained ghost cleanup: daemon publishes empty retained payload on old topic paths so brokers evict them

### Phase 4: daemon and iOS internal renames

- Daemon: `AgentManager`/`AgentHandle` → `RuntimeManager`/`RuntimeHandle`; `agent/` module → `runtime/`; `collab/` module deleted
- iOS: view model / view class renames
- No wire-format change in this phase; purely code hygiene

### Phase 5: delete legacy proto

- Remove `AgentInfo`, `AgentStartRequest`/`Result`, `AgentCommand`, `CommandEnvelope`, `DeviceCommandEnvelope`, `DeviceCollabEvent`, `DeviceCollabCommand` from `proto/amux.proto`
- Regenerate; adjust remaining references
- Update `CLAUDE.md` glossary — remove the "naming trap" section

### Compatibility window

- Phases 1–3: new daemon + old iOS works (old daemon still publishing old topics; old iOS subscribes there). Window bounded.
- Phase 3 onward: iOS must be at Phase 2 version or newer.
- Phase 5 requires all clients at Phase 4 or newer.

## Success Criteria

The redesign is successful when:

- `daemon/src/mqtt/topics.rs` is the only module producing topic strings
- `subscriber.rs` has a single `classify()` function with one test per `TopicShape` variant
- No daemon/iOS code uses the word `agent` for a Claude Code subprocess
- `CLAUDE.md`'s "naming trap" note is removed
- No Teamclaw-adjacent retained topic exists except `device/{id}/state` (LWT) and `runtime/{id}/state`
- iOS clients logged in as actor A receive invite events on `user/A/inbox` regardless of which daemon they are paired with
- Old `agent/{id}/*`, `collab`, `peers`, `workspaces`, `status` topics are fully removed from the codebase
- All proto messages referring to Claude Code subprocesses use `Runtime*` naming

## Open Questions

None at design time; all axes were resolved during brainstorming (scope, retained policy, terminology, command-channel count, inbox model).

## Summary

Collapse two topic modules into one. Rename `agent` → `runtime` end-to-end (wire + proto + daemon internals + iOS types). Fold `/collab` into `/rpc/req|res`. Drop retained `peers`/`workspaces` in favor of RPC + notify. Rename `status` → `state`. Add `user/{actor}/inbox` for cross-daemon targeted delivery. Replace ad-hoc subscriber parsing with a single table-driven classifier. Migrate in five dual-write phases so mixed-version clients keep working during rollout.
