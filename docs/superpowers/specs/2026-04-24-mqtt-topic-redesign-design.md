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
- retained topics that act as state stores where they shouldn't: `workspaces` (Supabase-authoritative, pure duplication) and `peers` (daemon-local presence, but the retained topic is currently the only recovery surface)
- leaf-name inconsistency (`status` vs `state`)
- ad-hoc string matching in `subscriber.rs` dispatch
- no user-scoped inbox for cross-daemon delivery

This is a coordinated wire-format and code change. Dual-write migration across 5 phases.

## Non-Goals

- Changing existing Supabase table/column names. **One new table** (`user_inbox` or equivalent) is within scope as a dependency of `user/{actor}/notify` — see Prerequisites.
- Redesigning the Teamclaw realtime contract; `session/{id}/live` + `notify` semantics from the prior spec are preserved
- Replacing ACP protocol names (`AcpEvent`, `AcpCommand` stay — they are external protocol names)
- Re-scoping what MQTT carries vs what Supabase carries

## Prerequisites

Two infrastructure changes must land **before** `user/{actor}/notify` ships (Phase 1). The rest of the redesign (runtime rename, RPC consolidation, retained cleanup) can proceed independently.

### P1. Supabase `user_inbox` table

`user/{actor}/notify` carries hints only; offline recovery requires an authoritative event log.

Minimum shape:
```
user_inbox
  id          uuid primary key
  actor_id    uuid references actors(id)
  team_id     uuid references teams(id)
  event_type  text
  refresh_hint text
  created_at  timestamptz
  read_at     timestamptz nullable
```

Write path — **transactional outbox**, because MQTT publishes are not covered by Postgres transactions:

1. Inside the same DB transaction that causes the event (e.g., `invite_to_session`), INSERT one row into `user_inbox` and one row into an `outbox` table (`outbox { id, topic, payload, created_at, published_at nullable }`).
2. Commit.
3. An after-commit hook (or a polling worker) reads unpublished `outbox` rows and publishes `Notify` to MQTT, updating `published_at` on success.
4. If the publisher crashes between commit and publish, the worker retries on restart. Duplicate publishes are acceptable — `Notify` is idempotent (the receiver re-queries Supabase either way).

This rules out the two failure modes of naive "publish inside transaction": (a) DB rolls back but MQTT already published a phantom hint, (b) DB commits but MQTT publish fails silently, leaving clients unhinted until next reconcile.

Read path: client reconciles by `SELECT ... WHERE actor_id = me AND read_at IS NULL`, processes, marks `read_at`. This is the offline-recovery path; online clients short-circuit via the MQTT `Notify` received in realtime.

### P2. Broker JWT auth

Current state: daemon (`daemon/src/mqtt/client.rs`) and iOS (`MQTTService.swift`) both use static username/password credentials. `user/{actor}/notify` ACL requires the broker to know *which actor* is on a connection, which username/password cannot express without a separate user per actor.

Migration:
- Broker (HiveMQ) configured to validate JWTs signed by Supabase auth
- Daemon/iOS issue a Supabase-signed JWT with `actor_id` / `team_ids` claims at CONNECT
- Broker ACL: `SUBSCRIBE user/{actor}/notify` allowed iff `actor_id` claim matches the path segment

Until both prereqs ship, Phase 1 can still deploy runtime/state/status renames and dual-write — just **do not publish `user/notify`** until the table exists and ACLs are enforced. `user/{actor}/notify` rollout is a gated sub-step of Phase 1 with its own readiness checklist.

## Problem

The Teamclaw rearchitecture established a clean signaling model for session realtime, but the device/runtime layer still carries older conventions:

1. **Two topic modules.** `daemon/src/mqtt/topics.rs::Topics` owns device/runtime topics. `daemon/src/teamclaw/topics.rs::TeamclawTopics` owns Teamclaw RPC/notify/session topics. Both produce strings under `amux/{team}/device/{id}/...` — splitting them by module hides that they share a namespace.

2. **`agent` vs `runtime` naming trap.** The wire path `device/{id}/agent/{id}/state` uses "agent" to mean a Claude Code subprocess. In Supabase, `agents` = daemon, and subprocesses live in `agent_runtimes`. Every reader has to mentally translate. Documented as a known gotcha in `CLAUDE.md`.

3. **Three command channels, three response patterns.**
   - `device/{id}/collab` — event-sourced replies back on `/collab`
   - `device/{id}/agent/{id}/commands` — replies as events on `/events`
   - `device/{id}/rpc/req` — strict request/response with `request_id` correlation on `/rpc/res`
   `collab` is structurally a device-scoped RPC in disguise.

4. **Retained state stores.** `device/{id}/peers` and `device/{id}/workspaces` retain list indexes that should not be on MQTT. Workspaces is Supabase-owned — that retained topic is pure duplication, same anti-pattern the Teamclaw rearchitecture removed. Peers is different: it is daemon-local ephemeral presence (in-memory `PeerTracker`, not Supabase-backed), and the retained topic is currently its only recovery surface for reconnecting clients. Removing it requires an explicit recovery model (see "Peers recovery model" below), not just a Supabase read.

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
  - `notify` — targeted invalidation hint ("refresh and re-fetch"). Two scopes: `device/{id}/notify` for daemon-local invalidation, `user/{actor}/notify` for user-wide (cross-daemon, within one team) invalidation. Both carry hints only — never full state.
  - `live` — session realtime stream
- **Retain only runtime-local snapshots.** `device/{id}/state` (LWT) and `runtime/{id}/state` are the only retained topics. Anything with a Supabase authoritative source is not retained.
- **Two command paths, by ownership.** Device-level operations go through `rpc/req|res`. Runtime-level ACP interaction goes through `runtime/{id}/commands` + `runtime/{id}/events`.
- **RPC replies confirm acceptance, not completion.** Any slow operation (runtime spawn, workspace registration, anything with a multi-step subprocess/IO dependency) must not block the RPC. The reply carries only `accepted | rejected + reason + allocated ids`. The actual lifecycle — progress, success, failure — is published exclusively on the retained state topic for that resource. Clients proceed on accept, show appropriate placeholder UI, and reconcile on state transitions. **This is not an option; requests that require waiting for completion are a design smell.** MQTT is not a synchronous RPC substrate for slow work.
- **`device/{id}` always addresses a daemon endpoint.** The id in the path is the daemon's `device_id` — never the publisher's, never an iOS client's. iOS clients do not have their own topic segment in this namespace; they participate in `device/{daemon_id}/...` topics based on pairing.
- **Requester identity lives in the payload, not the topic.** Because a single daemon's `rpc/res` is shared by every paired iOS client and by any other daemon that may address it, responses must carry enough identity in the payload for receivers to filter. See "Addressing and Identity" below.
- **Wire terminology matches Supabase where unambiguous.** Claude Code subprocess = `runtime` segment. "device" means daemon endpoint but the path is the addressing convention, not an identity claim about the publisher.

## Addressing and Identity

### Invariants (do not violate in any future change)

**I1. `device/{id}` in a topic path addresses a daemon endpoint. Nothing else.**
- The id is always a daemon's `device_id`.
- iOS / mac clients do **not** appear in any topic path as an id segment. Their install UUID, client id, or actor id must **never** be routed through `device/{id}/...`.
- Future features that need to address a specific iOS install must put that id in the payload (`requester_client_id`), not in the topic.
- This is how we avoid reintroducing the daemon-id-vs-requester-id confusion that the prior collab design leaked.

**I2. Requester identity is payload-only.**
- `requester_client_id`, `requester_actor_id`, `requester_device_id` travel in `RpcRequest` and are copy-through on `RpcResponse`.
- Never add a topic segment to encode who is asking. The target daemon's `rpc/res` is shared; filtering is the receiver's job via payload.

These invariants take precedence over convenience. If a proposed feature seems to require an iOS-addressed topic, the answer is a new RPC method on `device/{target_daemon}/rpc/req|res`, not a new `client/{id}/...` path.

### Identity roles

To keep the `device/{id}` namespace unambiguous, identity roles are defined up front:

| Role | Stable identifier | Where it lives |
|---|---|---|
| Daemon endpoint | `device_id` (string from `daemon.toml`) | Topic path: `device/{device_id}/...` |
| iOS / mac client | `client_id` (UUID per install, not in any topic path) | RPC payload field `requester_client_id` |
| Actor (signed-in user) | `actor_id` (Supabase auth row) | Topic path: `user/{actor_id}/notify`; RPC payload field `requester_actor_id` |
| Another daemon | the same `device_id` convention | RPC payload field `requester_device_id` |

### RPC envelope identity fields

Add to `RpcRequest`:
- `request_id: string` — correlation id (existing)
- `requester_client_id: string` — iOS client UUID; empty if not client-originated
- `requester_actor_id: string` — signed-in actor (always present for auth)
- `requester_device_id: string` — populated when another daemon is the caller

Add to `RpcResponse`:
- `request_id: string` — correlation id (existing)
- `requester_client_id: string` — copied through from the request
- `requester_actor_id: string` — copied through
- `requester_device_id: string` — copied through (for daemon-to-daemon caller)

All three identity fields are copied from request to response. Receivers on the shared `rpc/res` topic filter by whichever one they authored the request with.

### Response topic routing

The response **always** goes to the target daemon's own `rpc/res`:
```
target daemon publishes to: amux/{team}/device/{target_device_id}/rpc/res
```

All callers — iOS clients, other daemons — subscribe to the target's `rpc/res` for the duration of their pending requests (iOS: persistently while paired; daemon-to-daemon caller: subscribe on send, unsubscribe on correlated response or timeout). Filtering by copied-through requester id is cheap.

This means target daemon never "routes" a response to a different daemon's topic. That preserves the one-daemon-one-rpc/res invariant and keeps ACLs simple: each daemon owns its `rpc/res` for publish; everyone else is read-only.

The request topic follows the same rule — addresses the target daemon: `device/{target_device_id}/rpc/req`. Path encodes one route direction. "Who is asking" is payload-only.

### Why not split `daemon/{id}` vs `client/{id}`

Considered and rejected:
- iOS clients don't receive RPC directly; they only correlate on responses they care about. No client-addressed topic is needed.
- Splitting the namespace doubles the topic surface for no routing benefit. The existing `device/{id}` path is correct once its semantics are codified as "always addresses a daemon."
- Future daemon-to-daemon RPC reuses the same shape — `device/{other_daemon_id}/rpc/req` — without needing a new prefix.

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
amux/{team}/user/{actor}/notify
```

9 topic patterns, down from 11 active + 7 legacy placeholders.

### Topic details

**`device/{device}/state`** (retained; LWT-backed from Phase 3 onward)
- Replaces `device/{device}/status`
- Payload: `DeviceState { online: bool, version: string, started_at: timestamp }`
- End-state LWT publishes `online: false` on disconnect. **During Phases 1–2, LWT remains on legacy `status`**; `state` receives mirror publishes on graceful transitions only (see Phase 1 description). Phase 3 retargets LWT to `state` atomically.
- iOS `ConnectionMonitor` subscribes (dual-subscribes `status` + `state` during compat; see Subscription changes)

**`device/{device}/runtime/{runtime}/state`** (retained)
- Replaces `device/{device}/agent/{agent}/state`
- Payload: `RuntimeInfo` (renamed from `AgentInfo`) — carries the runtime's **full lifecycle**, not just a snapshot. See "Runtime lifecycle" below for the state machine the daemon publishes.
- First publish happens **the moment the daemon allocates a `runtime_id`** (before the Claude Code subprocess is spawned), with `state = STARTING` + initial `stage`. Subsequent stage/state transitions overwrite the retain as the spawn progresses.
- Cleared on graceful runtime termination after `STOPPED` is observed (retained empty payload evicts the retain)
- iOS subscribes via `device/{device}/runtime/+/state` wildcard (scoped to the paired daemon) and aggregates locally
- **`runtime_id` is a fresh 8-char UUID per spawn; not stable across daemon restarts of the same logical session.** Consequence: if the daemon crashes (LWT path, no graceful clear), `runtime/{old_id}/state` retains the last snapshot indefinitely. Cleanup mechanism — MQTT has no "list retained topics" API, so the daemon uses its only available signal, a transient wildcard subscription:
  1. On startup, daemon subscribes to `device/{own_id}/runtime/+/state`
  2. Broker delivers all currently-retained runtime states as the subscription establishes
  3. Daemon collects `runtime_id`s from the received retains, diffs against its fresh-spawn set (which is empty at startup), marks all of them as orphans
  4. For each orphan, daemon publishes empty retained payload on `runtime/{orphan_id}/state`
  5. Daemon unsubscribes (it does not handle inbound `RuntimeState` steady-state — it's the sole publisher)
  Window: orphan cleanup happens in the first few seconds of daemon startup. Clients reconnecting in that window may briefly see ghost retains; they self-correct when the daemon republishes its current runtime set. This is the only place the daemon transiently consumes `RuntimeState`.

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

**`user/{actor}/notify`** (ephemeral, new)
- User-scoped invalidation channel. Scope is **one team**: the path is `amux/{team}/user/{actor}/notify`. An actor in N teams subscribes to N topics (one per team). Cross-team fan-out is out of scope for this spec.
- Use cases: "you were invited to session X — refresh", membership/permission changes that should reach the user across all their clients
- All clients logged in as `actor` within this team subscribe, regardless of which daemon they are paired with
- Payload: `Notify { event_type, refresh_hint, sent_at }` — hint only, never full state. Authoritative data lives in Supabase; the client pulls on hint. Same `Notify` shape is reused on `device/{id}/notify`.
- **Offline delivery is explicitly NOT provided by MQTT.** If every client of `actor` is disconnected at publish time, the notify is lost on the wire. The authoritative record has already been written to Supabase (the `user_inbox` table, or equivalent) by whoever caused the event; online recovery is "reconnect, reconcile Supabase table, clear reconciled rows." Offline wake-up is APNs, not MQTT. This preserves the "MQTT is signaling, not storage" principle from the prior spec.
- Broker ACL must restrict `SUBSCRIBE` on `user/{actor}/notify` to the matching authenticated actor (enforced via HiveMQ JWT claim `actor_id`).

### `device/notify` vs `user/notify` scoping

Both topics carry invalidation hints only. They differ in subscriber scope and what the notify is trying to wake.

| Concern | `device/{id}/notify` | `user/{actor}/notify` |
|---|---|---|
| Subscriber scope | One daemon + clients paired with it | All clients logged in as `actor` in this team |
| Typical trigger | Daemon-local state changed (peers, workspaces) | Cross-device user-scoped change (invite, membership, permission) |
| Payload | Hint only, never full state | Hint only, never full state |
| Authoritative data lives in | Supabase | Supabase |
| Offline delivery on the wire | No (recover on reconnect via Supabase) | No (recover on reconnect via Supabase; APNs wakes if needed) |

Both scopes use the same recovery path: client reconnects, reads current truth from Supabase, reconciles local state. MQTT is the latency optimization for online clients, never the source of truth.

### Removed topics

| Topic | Replacement |
|---|---|
| `device/{id}/status` | `device/{id}/state` (renamed, retained, LWT) |
| `device/{id}/peers` | RPC `FetchPeers` (returns daemon's in-memory `PeerTracker`) + `device/{id}/notify` on change. See "Peers recovery model". |
| `device/{id}/workspaces` | RPC `FetchWorkspaces` (Supabase-backed) + `device/{id}/notify` on change |
| `device/{id}/collab` | Split: requests on `rpc/req`, broadcasts on `device/{id}/notify` or `user/{actor}/notify` |
| `device/{id}/agent/{id}/*` | `device/{id}/runtime/{id}/*` (renamed) |
| Legacy `MQTTTopics.swift` methods (`sessions`, `members`, `messages`, `tasks`, `presence`, `actor-meta`, per-request rpc) | Already unused; delete the dead code |

## Peers recovery model

Unlike workspaces, peers are **not** in Supabase. `PeerTracker` (`daemon/src/collab/peers.rs`) is an in-memory `HashMap<peer_id, PeerState>` populated at runtime by `AnnouncePeerRequest` / `DisconnectPeerRequest` RPCs. A daemon restart loses the peer set; today's retained `device/{id}/peers` rebuilds it for reconnecting clients but offers nothing to the daemon itself.

The new model stays runtime-local, but recovery is explicit:

1. **Cold start.** A reconnecting iOS/mac client issues `FetchPeersRequest` to the paired daemon and receives the daemon's current in-memory set. No retained topic involved.
2. **Steady-state invalidation.** On any peer change (add/remove/disconnect), the daemon publishes `Notify { event_type: "peers.changed" }` to `device/{id}/notify`. Clients re-call `FetchPeers` on hint. No full list on the wire.
3. **Daemon restart.** On daemon restart, the peer set is empty by definition. Clients that had peers tracked locally will find `FetchPeers` returns an empty list, reconcile their local state to empty, and re-announce their own presence if applicable.
4. **Re-announce policy.** Every client on successful MQTT connect re-issues `AnnouncePeerRequest`. This is the authoritative presence signal, replacing retained-topic reconstruction.

`FetchPeersResponse` carries the full peer list inline — there is no cursor/pagination. At current scale (tens of peers per daemon) this is acceptable. If it becomes a bottleneck, `FetchPeers` can paginate or be replaced with a cursor-based stream; that is out of scope here.

## Runtime lifecycle

A Claude Code subprocess spawn is not instantaneous — it includes process fork, ACP initialize, ACP session creation, model selection, and Supabase `agent_runtimes` upsert. In practice this takes hundreds of ms to several seconds. `StartRuntimeRequest` must not block on completion.

### State machine

`RuntimeInfo.state` is one of:

| State | Meaning | Terminal? |
|---|---|---|
| `STARTING` | `runtime_id` allocated; spawn is in progress. `stage` narrows current step. | no |
| `ACTIVE` | Ready to receive `runtime/{id}/commands`. ACP session is open, model is set. | no |
| `FAILED` | Spawn or runtime aborted. `error` carries a human-readable message and a stable code. | yes |
| `STOPPED` | Runtime terminated cleanly (on `StopRuntimeRequest` or runtime-initiated exit). | yes |

Allowed transitions:
- `STARTING → ACTIVE` — normal success path
- `STARTING → FAILED` — spawn failed before reaching ACTIVE
- `ACTIVE → FAILED` — runtime died unexpectedly (subprocess crash, ACP stream closed)
- `ACTIVE → STOPPED` — graceful shutdown
- `STARTING → STOPPED` — cancellation before ACTIVE (rare but allowed)

Terminal states are retained. `FAILED` retains until the user explicitly dismisses / a cleanup policy expires; `STOPPED` retains briefly then clears.

### Stage field (only meaningful when `state == STARTING`)

| `stage` | What the daemon is doing |
|---|---|
| `spawning_process` | forking the Claude Code subprocess |
| `acp_connecting` | opening the ACP stdio stream |
| `acp_initializing` | exchanging ACP `initialize` handshake |
| `creating_acp_session` | creating the ACP session |
| `setting_model` | applying the initial model selection |
| `persisting` | Supabase `agent_runtimes` upsert |

Stage is informational (for UI progress display). iOS must tolerate unknown stage strings — new stages can be added without a proto rev.

### Error field (only meaningful when `state == FAILED`)

```
error_code: string   // stable, enum-like (e.g. "ACP_INIT_TIMEOUT", "MODEL_UNAVAILABLE")
error_message: string // human-readable
failed_stage: string  // which STARTING stage was running, or "runtime" for post-ACTIVE deaths
```

A `FAILED` state without populated error fields is a daemon bug — iOS should surface "unknown daemon error" rather than silently hide the failure.

### Publish timing

1. Daemon receives `StartRuntimeRequest`, validates, allocates `runtime_id`.
2. **Before spawning anything**, daemon publishes `RuntimeInfo { state: STARTING, stage: "spawning_process", ... }` to `runtime/{runtime_id}/state` (retained).
3. Daemon sends `StartRuntimeResult { accepted: true, runtime_id, session_id }`.
4. Spawn proceeds asynchronously; daemon publishes retained state updates at every stage boundary.
5. On success: `state: ACTIVE`. On any failure: `state: FAILED` with populated error fields.
6. On `StopRuntimeRequest` (accepted reply first), daemon publishes `state: STOPPED` after termination completes.

The retained state is always authoritative. A client that reconnects mid-spawn sees the current retained state (possibly `STARTING` with a stage), no history replay needed.

### Client (iOS/mac) behavior

- On `StartRuntimeResult { accepted }`: navigate into the session/runtime detail view immediately with a "starting..." placeholder. Do not block on `ACTIVE`.
- Subscribe to `runtime/{allocated_id}/state` as soon as the accepted reply arrives.
- UI gates:
  - `STARTING` → show placeholder with current stage ("spawning process...", "connecting to Claude...", etc.). Inputs are either disabled or queued locally.
  - `ACTIVE` → fully interactive; send queued inputs.
  - `FAILED` → show error surface with `error_message`; offer retry (retry = a new `StartRuntimeRequest`).
  - `STOPPED` → detail view shows terminated state; no more input.
- If the retained state is missing on subscribe (broker-side race, daemon crash before first publish), client falls back to "unknown — retry?" after a short timeout. Do not assume silence means ACTIVE.

## Proto Changes

### Renamed messages (`proto/amux.proto`)

| Old | New | Strategy | Notes |
|---|---|---|---|
| `AgentInfo` | `RuntimeInfo` | Rename in place (Phase 0) + extend with lifecycle fields (`state` enum, `stage`, `error_code`, `error_message`, `failed_stage`) | Payload of `runtime/{id}/state`; see "Runtime lifecycle" |
| `AgentStartResult` | `RuntimeStartResult` | Rename in place | RPC result variant |
| `AgentStartRequest` | `RuntimeStartRequest` | Rename in place | RPC request variant |
| `AgentCommand` | `RuntimeCommand` | Rename in place | `runtime/{id}/commands` payload oneof |
| `DeviceStatus` | `DeviceState` | Rename in place | Payload of `device/{id}/state` |
| `CommandEnvelope` | `RuntimeCommandEnvelope` | **Dual existence** (Phase 0 adds new; Phase 5 removes old) | Old envelope keeps flowing on legacy `agent/{id}/commands` during dual-publish; new envelope on `runtime/{id}/commands` |
| `AcpEvent` | (unchanged) | — | ACP is an external protocol name |
| `AcpCommand` | (unchanged) | — | Same |

### Deleted messages

| Message | Reason |
|---|---|
| `DeviceCommandEnvelope` | Folded into RPC request payload types |
| `DeviceCollabEvent` | Split: sync results → RPC response; async broadcasts → `device/{id}/notify` or `user/{actor}/notify` |
| `DeviceCollabCommand` | Each variant becomes an RPC method variant |

### Renamed fields

- All `agent_id` fields naming a Claude Code subprocess → `runtime_id`
- Supabase foreign-key fields that truly reference `agents.id` (daemon identity) keep the `agent_id` name — they point at Supabase's `agents` table

### New RPC methods (to replace `DeviceCollabCommand` variants)

Added to `RpcRequest.method` oneof:
- `StartRuntimeRequest` — request a new Claude Code subprocess spawn. **Accepted/rejected only** — this is the primary new-session path, and the daemon **must not** block the reply on subprocess readiness. See "Runtime lifecycle" section for the state machine that reports actual spawn progress. Old `agent/new/commands` is removed; the only way to initiate a runtime spawn is this RPC.

  **Bare-agent spawn must remain supported.** The "Just you → new session → Agent" flow we recently verified spawns a runtime with no Supabase session, potentially no workspace, and a daemon-chosen worktree. The new RPC must not tighten field requirements in a way that breaks this path.

  Request fields (ported from today's `AcpStartAgent` with explicit optionality):
  ```
  agent_type      AgentType       // required
  initial_prompt  string          // optional — first user message sent at spawn
  model_id        string          // optional — initial model selection; empty = daemon default

  // ——— all three below are OPTIONAL; empty = bare-agent spawn ———
  workspace_id    string          // empty = no workspace binding
  worktree        string          // empty = daemon picks a default working directory
  session_id      string          // empty = no Supabase sessions.id linkage; agent_runtimes row has NULL session_id (current "legacy bare-agent" behavior, preserved verbatim)
  ```

  Daemon behavior matrix:

  | `workspace_id` | `worktree` | `session_id` | Interpretation |
  |---|---|---|---|
  | set | set | set | Full workspace+session bound spawn (today's "from session list" path) |
  | set | set | empty | Workspace-bound spawn with no Supabase session (intermediate legacy) |
  | empty | empty | empty | **Bare-agent spawn** — "Just you" flow, daemon picks worktree, no workspace/session linkage |
  | empty | set | * | Worktree-only spawn (manual override); `workspace_id` inferred or left null |
  | set | empty | * | Daemon resolves worktree from `workspace_id` registration |

  Validation failures surface in `StartRuntimeResult.rejected_reason` and do not cause a retained state publish. Other combinations not listed above are validation errors. The validation table is part of the RPC contract; do not add implicit required-ness in code.

  Reply: `StartRuntimeResult`
  ```
  accepted           bool
  runtime_id         string    // allocated by the daemon; present iff accepted
  session_id         string    // echoed (new if daemon created one) or empty for bare-agent spawn
  rejected_reason    string    // set iff !accepted (validation / auth / resource error)
  ```
  **Does NOT include `RuntimeInfo`.** All readiness/progress flows on `runtime/{runtime_id}/state`. On accepted, the daemon has already published initial `RuntimeInfo { state: STARTING, stage: "spawning_process" }` to the retained state topic by the time the reply is on the wire (publish happens before reply is sent). The client subscribes to `runtime/{runtime_id}/state` as soon as the reply arrives; it will either receive the current retain immediately or race the first daemon publish — both paths converge on the same retained state.
- `StopRuntimeRequest` — request termination of a runtime. Accepted-only reply. Actual termination observable as `state: STOPPED` (or `FAILED` if shutdown errored) on `runtime/{id}/state`; daemon clears the retain after the terminal state has been observed briefly. No synchronous "stopped" confirmation in the RPC.
- `AnnouncePeerRequest` (was `PeerAnnounce`)
- `DisconnectPeerRequest` (was `PeerDisconnect`)
- `RemoveMemberRequest` (was `RemoveMember`)
- `AddWorkspaceRequest` (was `AddWorkspace`)
- `RemoveWorkspaceRequest` (was `RemoveWorkspace`)
- `FetchPeersRequest` (new — replaces retained `peers` topic; returns daemon's in-memory peer set, see "Peers recovery model" below)
- `FetchWorkspacesRequest` (new — replaces retained `workspaces` topic)

Corresponding result variants added to `RpcResponse.result`. `StartRuntimeResult` is deliberately minimal (see above) — it does not contain `RuntimeInfo`. Readiness is observed on the retained state topic, not the RPC reply.

### New envelope

- `Notify` — single shared payload for **both** `device/{id}/notify` and `user/{actor}/notify`
  ```
  event_type: string   // "invite.received" | "peers.changed" | "workspaces.changed" | "membership.changed" | ...
  refresh_hint: string // optional: resource id hint ("session/abc") to narrow what to re-fetch
  sent_at: int64
  ```
  Intentionally carries no body. All state reads go to Supabase or to daemon RPCs. The same message type is used regardless of topic scope — `event_type` namespaces itself (`peers.*` is device-scoped by convention, `invite.*` is user-scoped). Receivers route by `event_type`, not by message type.

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
    pub fn user_notify(&self, actor_id: &str) -> String;
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
    UserNotify     { actor_id: String },
}

pub struct TopicSegments {
    pub team_id: String,
    pub device_id: Option<String>,
}

pub fn classify(topic: &str) -> Option<(TopicShape, TopicSegments)>;
```

One function, exhaustive match in callers, one unit test per shape.

**Role-specific matching.** Daemon and iOS share `classify()` but handle disjoint inbound sets:

| Variant | Daemon inbound | iOS inbound |
|---|---|---|
| `DeviceRpcReq` | yes | no |
| `DeviceRpcRes` | no | yes |
| `DeviceNotify` | yes | yes (when paired with this device) |
| `DeviceState` | no (self-published) | yes |
| `RuntimeState` | startup-transient only (orphan cleanup, see `runtime/{id}/state` description); otherwise no — daemon is the sole publisher | yes |
| `RuntimeEvents` | no (self-published) | yes (foreground runtime) |
| `RuntimeCommands` | yes (own wildcard) | no |
| `SessionLive` | yes (daemon session set) | yes (foreground session) |
| `UserNotify` | no | yes |

Irrelevant variants fall through silently in each caller. The shared classifier just ensures the parse is correct; routing logic is role-local.

## iOS Code Changes

### SwiftData model renames

| Old | New |
|---|---|
| `Agent` (`@Model`) | `Runtime` |
| `AgentEvent` | `RuntimeEvent` |
| `Agent.agentId` | `Runtime.runtimeId` |

Requires a SwiftData schema migration. SwiftData lightweight migration does not reliably handle `@Model` type renames with relationship graphs; a custom migration stage is needed.

Strategy (pick one, documented in the Phase 2 PR):
- **Custom `VersionedSchema` + `SchemaMigrationPlan`.** Explicit old→new stage mapping `Agent` → `Runtime`, `AgentEvent` → `RuntimeEvent`, with a handwritten migration that rewrites relationship references. Tested by upgrading from a pre-Phase-2 store.
- **Destructive reset.** Bump schema version, wipe the local SwiftData store on first launch of the new build, re-hydrate `Runtime`/`RuntimeEvent` from MQTT retained state + Supabase. Simpler and lower risk; acceptable because runtime/event history is all recoverable (retained `runtime/{id}/state`, sessions reloaded from Supabase, events re-stream on subscribe).

Default to the destructive reset unless there is a concrete reason to preserve local-only state. The custom-migration path costs a week of iOS work and has its own regression risk.

### ViewModel / view renames

| Old | New |
|---|---|
| `AgentDetailViewModel` | `RuntimeDetailViewModel` |
| `AgentDetailView` | `RuntimeDetailView` |
| `AgentListViewModel` / similar | `RuntimeListViewModel` |

### `MQTTTopics.swift`

Renamed methods (end-state; during the Phase 2 compat window both old and new methods exist side-by-side, old ones are deleted in Phase 3):
- `agentState` → `runtimeState`
- `agentStateWildcard` → `runtimeStateWildcard`
- `agentStatePrefix` → `runtimeStatePrefix`
- `agentEvents` → `runtimeEvents`
- `agentCommands` → `runtimeCommands`
- `deviceStatus` → `deviceState` — note `deviceStatus` is **kept** in Phase 2 because iOS still subscribes to `device/{id}/status` for LWT crash detection; removed in Phase 3 together with the daemon-side topic retirement

Deleted methods:
- `devicePeers`, `deviceWorkspaces` — replaced by RPC
- All legacy placeholders: `sessions`, `members`, session `messages` / `tasks` / `presence`, `actor-meta`, per-request RPC

New method:
- `userNotify(teamID:, actorID:)` → `amux/{team}/user/{actor}/notify`

### Subscription changes

| Component | Change |
|---|---|
| `TeamclawService` startup | Add `userNotify` subscription for the logged-in actor (one per joined team). Remove `devicePeers`, `deviceWorkspaces` subscriptions. |
| `ConnectionMonitor` | Subscribe to BOTH `deviceStatus` and `deviceState` during the compat window; merge with offline-wins. Drops `deviceStatus` subscription in Phase 3 after daemon LWT moves. |
| `SessionListViewModel` | Stop reading retained `workspaces`; call RPC `FetchWorkspaces` on cold start; refresh on `notify` hint |
| `RuntimeListViewModel` | Unchanged shape; subscribe to `runtime/+/state` wildcard |

## Migration Plan

Five phases. Phases 1–3 maintain dual-path compatibility so mixed-version clients work.

### Phase 0: proto changes, both-sides compile

Proto message names are compile-time identifiers, not wire format — field numbers govern the wire. Pure renames don't need dual existence; they're a single recompile on both ends.

- **Rename in place** (one commit, recompile both ends):
  - `AgentInfo` → `RuntimeInfo`
  - `AgentStartRequest`/`Result` → `RuntimeStartRequest`/`Result`
  - `AgentCommand` → `RuntimeCommand`
  - `DeviceStatus` → `DeviceState`
  - All `agent_id` fields naming a Claude Code subprocess → `runtime_id` (field numbers unchanged)
- **Dual existence (genuinely required)**:
  - Keep `CommandEnvelope`; add `RuntimeCommandEnvelope` alongside. Old envelope keeps flowing on legacy `agent/{id}/commands` during the dual-publish window; new envelope flows on `runtime/{id}/commands`. Retire the old one in Phase 5.
  - Add new RPC method/result variants to existing `RpcRequest`/`RpcResponse` oneofs. Adding variants is wire-compatible: older readers see unknown oneof cases and ignore them, which is the correct behavior for absorbed collab operations (daemon is the only server; if it's old, iOS falls back to `/collab`).
- **Added fields on existing messages**:
  - `RpcRequest`: `requester_client_id`, `requester_actor_id`, `requester_device_id` (new string fields, empty on pre-Phase-0 callers — receivers must tolerate empty)
  - `RpcResponse`: same three fields (copy-through from the request; receiver filters by whichever id it sent with)
- **Added messages**:
  - `Notify` payload (shared by `device/notify` and `user/notify`; see Proto Changes above)
- Regenerate Rust + Swift proto code. Both ends compile. No wire-format change yet.

### Phase 1: daemon dual-publishes and dual-subscribes

- Merge `TeamclawTopics` into `Topics`; rename old methods in `Topics`
- Daemon publishes to **both** old and new paths for overlapping topics:
  - Runtime state: `device/{id}/agent/{id}/state` **and** `device/{id}/runtime/{id}/state` (same `RuntimeInfo` payload on both after Phase 0; both retained)
  - Events: `agent/{id}/events` **and** `runtime/{id}/events`
  - Device state: `device/{id}/status` **and** `device/{id}/state` (both retained). MQTT allows exactly one LWT per connection, so crash-driven offline detection can only happen on one topic. **LWT stays on `status` through Phase 2 (unchanged from today)**. New `state` topic receives mirror publishes on every normal transition and a manual offline publish on graceful shutdown, but is **not LWT-backed** during the compat window. Phase 3 atomically moves the LWT target to `state` when `status` is retired.
    - **Phase 2 iOS strategy (decided)**: iOS subscribes to BOTH `device/{id}/status` and `device/{id}/state` during the compat window. Local merge rule: **offline wins** — if either topic currently reads offline, the device is offline. This makes crash detection reliable (via `status` LWT) and forward-migration seamless (via `state`). Phase 3 drops the `status` subscription.
  - **On runtime termination, empty retained payload is published to BOTH the old and new state topics** — otherwise legacy subscribers see ghost state. Same rule at daemon shutdown for device state (graceful path).
- Daemon subscribes to **both** old and new command paths:
  - `agent/+/commands` and `runtime/+/commands`
  - `collab` still accepted; new `rpc/req` accepts absorbed collab operations
- Daemon starts publishing `Notify` to `user/{actor}/notify` for invite/membership events, via the transactional outbox described in Prerequisites (DB commit first, publish after)
- Peers/workspaces: daemon still publishes retained topics AND answers new `FetchPeers`/`FetchWorkspaces` RPCs AND emits `notify` on change

### Phase 2: iOS switches to new paths

- `MQTTTopics.swift` updated; all call sites point to new paths
- SwiftData schema migration (`Agent` → `Runtime`)
- iOS publishes commands on `runtime/{id}/commands` and `rpc/req` (absorbed collab operations)
- iOS subscribes to `runtime/+/state`, `runtime/{id}/events`, `device/{id}/state` **and** `device/{id}/status` (dual-subscribe; offline-wins merge per the LWT compat rule — drops `status` in Phase 3), `device/{id}/notify`, `device/{id}/rpc/res`, `user/{actor}/notify`, `session/{id}/live` (per foreground session)
- iOS stops reading retained `peers` / `workspaces`; uses RPC + notify
- Legacy `MQTTTopics.swift` methods deleted
- iOS release ships

### Phase 3: daemon stops old paths

- Daemon stops publishing to `agent/{id}/state`, `agent/{id}/events`, `device/{id}/status`, `device/{id}/peers`, `device/{id}/workspaces`, `device/{id}/collab`
- Daemon stops subscribing to `agent/+/commands`, `collab`
- Daemon removes `/collab` topic constants from `Topics`
- **LWT retarget**: daemon reconnects with LWT pointing at `device/{id}/state` instead of `status`. This is the atomic crossover point for crash-driven offline detection. After this phase, `state` is the sole source of truth for device online/offline.
- Retained ghost cleanup: daemon publishes empty retained payload on old topic paths (`status`, `peers`, `workspaces`, all `agent/{id}/*`) so brokers evict them. Any iOS client still on a pre-Phase-2 build is past its supported window and is expected to upgrade.

### Phase 4: daemon and iOS internal renames

**This phase is wire-independent and can run in parallel with Phases 0–3, or even before them.** The rename is pure source-level refactor. Running it right after Phase 0 (before the dual-write window opens) reduces the "agent vs runtime" cognitive overhead throughout Phases 1–3, at the cost of a larger Phase-0-adjacent diff. Running it last (as originally numbered) keeps Phase 0 minimal but forces reviewers to mentally translate `agent` → `runtime` throughout the migration. Pick based on reviewer/author capacity.

- Daemon: `AgentManager`/`AgentHandle` → `RuntimeManager`/`RuntimeHandle`; `agent/` module → `runtime/`; `collab/` module deleted (operations already absorbed into `teamclaw/rpc.rs` by Phase 1)
- iOS: view model / view class renames
- No wire-format change in this phase; purely code hygiene

### Phase 5: delete legacy proto

Most messages are already renamed in place in Phase 0. This phase only removes the messages that required dual existence or were fully folded into other types.

- Remove `CommandEnvelope` (dual existence partner; `RuntimeCommandEnvelope` is the only envelope from now on)
- Remove `DeviceCommandEnvelope` (folded into RPC request payload types)
- Remove `DeviceCollabEvent`, `DeviceCollabCommand` (split into RPC + notify)
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
- Spawning a new Claude Code subprocess goes exclusively through `StartRuntimeRequest` on `rpc/req`; no code path publishes to `agent/new/commands` or any runtime topic without a known `runtime_id`
- Bare-agent spawn (empty `workspace_id` + empty `worktree` + empty `session_id`) still succeeds end-to-end — the "Just you → new session → Agent" flow continues to work against the new protocol
- `StartRuntimeResult` arrives within one round-trip (no blocking on subprocess readiness); daemon publishes `RuntimeInfo { state: STARTING }` to the retained state topic before the reply leaves the wire
- Runtime lifecycle transitions (`STARTING → ACTIVE`, `STARTING → FAILED`, `ACTIVE → FAILED`, `* → STOPPED`) are all observable on `runtime/{id}/state` — verified by forcing a spawn failure (e.g., invalid model) and confirming iOS surfaces the `error_message` rather than loading indefinitely
- No daemon code path reports a runtime failure only via logs; every failure produces a `state: FAILED` retain with populated `error_code` / `error_message`
- Daemon startup orphan cleanup reliably empties retained payloads left by the previous (possibly crashed) daemon process, verified by restarting a daemon with live retained state and observing zero ghost runtimes from the client side
- iOS clients logged in as actor A in team T receive invite/membership hints on `amux/T/user/A/notify` regardless of which daemon they are paired with, and reconcile from Supabase `user_inbox`
- Broker ACL rejects subscribe attempts on `user/{actor}/notify` where the JWT `actor_id` claim does not match the path
- Old `agent/{id}/*`, `collab`, `peers`, `workspaces`, `status` topics are fully removed from the codebase
- All proto messages referring to Claude Code subprocesses use `Runtime*` naming
- `device/{id}` path is documented as "daemon endpoint, not publisher identity"; requester identity flows in RPC payload fields (`requester_client_id` / `requester_actor_id` / `requester_device_id`)

## Open Questions

None at design time; all axes were resolved during brainstorming (scope, retained policy, terminology, command-channel count, inbox model).

## Summary

Collapse two topic modules into one. Rename `agent` → `runtime` end-to-end (wire + proto + daemon internals + iOS types). Fold `/collab` into `/rpc/req|res`. Drop retained `peers`/`workspaces` in favor of RPC + notify. Rename `status` → `state`. Add `user/{actor}/notify` as a user-scoped, hint-only invalidation channel backed by a Supabase inbox table (no MQTT-as-storage). **Split acceptance from completion**: `StartRuntimeRequest` / `StopRuntimeRequest` return `accepted` fast; actual lifecycle (`STARTING` / `ACTIVE` / `FAILED` / `STOPPED` with stage and error fields) flows on the retained `runtime/{id}/state` topic, so iOS never blocks on a slow spawn and daemon-side failures are always surfaced. Replace ad-hoc subscriber parsing with a single table-driven classifier. Migrate in five phases — most proto renames are single-commit, only `CommandEnvelope` needs dual existence — so mixed-version clients keep working during rollout.
