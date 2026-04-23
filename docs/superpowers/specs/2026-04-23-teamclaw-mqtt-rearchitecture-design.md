# Teamclaw MQTT Rearchitecture — Design Spec

**Status**: draft
**Date**: 2026-04-23
**Scope**: daemon MQTT routing + iOS/mac session subscription model + Teamclaw realtime contract

## Goal

Rebuild Teamclaw's MQTT layer so it scales to large teams and high session churn without using MQTT as a state store. The new design optimizes for three things:

- broker scalability
- low client reconnect cost
- simple server-side behavior

Session lists, membership truth, and history are out of scope for MQTT. They remain on Supabase and explicit RPC reads.

## Non-Goals

- Realtime recovery from broker-retained session state
- Team-wide retained indexes such as `amux/{team}/sessions`
- MQTT as the source of truth for session metadata, actor membership, or history
- Solving session discovery or list pagination in MQTT

## Problem

The current Teamclaw design still carries stateful MQTT patterns that work for small teams but degrade badly as session count grows:

- team-wide retained indexes (`team/sessions`) grow linearly with total historical sessions
- per-actor retained session metadata fans out retained topics by participant count
- reconnect cost depends on retained broker state rather than the user's current working set
- clients subscribe to session-scoped topics without a strict lifecycle, so subscription count grows with historical usage

At roughly 200 people per team and 5,000 new sessions per day, the problem is not the raw number of topic names. The problem is unbounded retained state, full-index republishes, and reconnect behavior that scales with historical sessions instead of active sessions.

## Design Principle

MQTT is a realtime signaling bus, not a database and not a cache restoration layer.

That means:

- MQTT carries only hot, in-flight realtime data
- Supabase is the source of truth for session membership and list queries
- explicit RPC or database reads recover state after reconnect
- retained usage is disallowed for Teamclaw session state

The only retained topic that may remain is device online/offline if AMUX still needs it for LWT-style connectivity. Teamclaw session traffic should not depend on retained delivery.

## Topic Model

The new contract collapses Teamclaw onto four topics:

```text
amux/{team}/device/{device}/rpc/req
amux/{team}/device/{device}/rpc/res
amux/{team}/device/{device}/notify
amux/{team}/session/{session}/live
```

### 1. Device RPC

`device/{device}/rpc/req` and `device/{device}/rpc/res` are point-to-point request/response channels.

Use them for:

- create session
- join session
- add/remove participant
- fetch recent messages
- catch-up after reconnect
- daemon-targeted commands

Rules:

- no `request_id` in the topic path
- request/response matching happens in payload
- no retained messages
- one constant subscription per device for req/res

### 2. Device Notify

`device/{device}/notify` is a targeted invalidation channel.

Use it for:

- "you were added to session X"
- "membership changed for session X"
- "refresh your subscribed session set"
- "wake up and fetch"

Rules:

- notify does not carry full state
- notify tells the receiver what to refresh, not the new truth itself
- no retained messages
- fan-out is only to affected devices, never whole-team broadcast

### 3. Session Live

`session/{session}/live` is the only Teamclaw session realtime stream.

Use it for all online session events:

- message created
- task created/updated
- typing started/stopped
- presence joined/left
- lightweight system events

This replaces separate session topics such as:

- `/messages`
- `/tasks`
- `/presence`
- session metadata fan-out topics

One session gets one live stream. Topic layout is for routing, not for mirroring the data model.

## Envelope Contract

All `session/{session}/live` payloads use one envelope shape:

```json
{
  "event_id": "uuid",
  "event_type": "message.created",
  "session_id": "sess_123",
  "actor_id": "member_456",
  "sent_at": 1770000000,
  "body": {}
}
```

`event_type` is an application-level field, not a topic segment. Initial types:

- `message.created`
- `task.created`
- `task.updated`
- `presence.joined`
- `presence.left`
- `typing.started`
- `typing.stopped`
- `system.member_added`
- `system.member_removed`

This keeps broker complexity flat while allowing the payload schema to evolve independently.

## Roles and Subscription Strategy

The system must distinguish between app clients and daemons. They have different realtime needs.

### App Clients

iOS and macOS app clients keep only device-scoped subscriptions by default:

- `device/{device}/rpc/req`
- `device/{device}/rpc/res`
- `device/{device}/notify`

They subscribe to `session/{session}/live` only for sessions currently open in the foreground UI.

Rules:

- entering a session subscribes
- leaving a session unsubscribes
- backgrounded historical sessions are not kept subscribed

This makes reconnect cost proportional to the user's active UI context, not their historical session count.

### Daemon

The daemon also keeps the same device-scoped subscriptions:

- `device/{device}/rpc/req`
- `device/{device}/rpc/res`
- `device/{device}/notify`

But it additionally maintains a background subscription set for every session where the daemon is currently a participant.

Important distinction:

- app client subscription set = sessions open in UI
- daemon subscription set = sessions where this daemon must actively participate

The daemon's session set comes from Supabase membership truth, not from MQTT-retained state.

## Membership and Invite Flow

Session membership truth lives outside MQTT.

Recommended write path:

1. caller invokes `add_participant` or `invite_to_session`
2. server writes the membership/invite truth to Supabase
3. server sends targeted `device/{device}/notify` to affected devices
4. receiving client/daemon refreshes membership state and adjusts live subscriptions if needed

### Why notify instead of session broadcast

Inviting someone should not publish to a team-wide channel, and does not need to appear on `session/live` before the invitee has joined.

`notify` is the correct mechanism because:

- fan-out is targeted
- offline devices can still recover from Supabase later
- the broker does not become the source of truth for membership

## Reconnect Model

Reconnect must be explicit and deterministic.

### App reconnect

1. reconnect MQTT transport
2. resubscribe device-scoped topics
3. if a session is currently open, fetch latest state from Supabase
4. subscribe to that session's `live`
5. optionally run catch-up RPC if there may be a gap between fetch and subscription establishment

This accepts a simple rule: MQTT alone is not sufficient to reconstruct state after reconnect.

Current implementation note:

- `membership.refresh` on iOS/macOS triggers an explicit refresh path, but that path still assumes the session is already known locally well enough to resolve its host device for `FetchSession` RPC.
- A completely unknown session still requires some other source of truth bootstrap before the app can hydrate it from MQTT-triggered invalidation alone.

### Daemon reconnect

1. reconnect MQTT transport
2. resubscribe device-scoped topics
3. fetch the daemon's active session membership set from Supabase
4. diff current subscriptions against the fetched set
5. subscribe/unsubscribe `session/{session}/live` accordingly
6. run catch-up RPC per active session when needed

This makes daemon behavior scale with "sessions the daemon actively participates in," not "sessions in the team."

## Catch-Up Strategy

Because MQTT is no longer a replay layer, the system needs an explicit gap-recovery mechanism.

Recommended model:

- history and current truth: Supabase reads
- short reconnect window recovery: explicit `fetch_recent_messages` or `catch_up_session` RPC

The catch-up RPC is responsible only for the gap between "last known cursor" and "subscription is live again." It should not become a second history API.

Suggested client metadata:

- last seen message timestamp per session
- last seen event timestamp or cursor per session

Suggested daemon metadata:

- last processed event cursor per active session

## Presence

Presence should start as ephemeral events on `session/{session}/live`, not a dedicated retained topic.

Initial behavior:

- on entering a live session, emit `presence.joined`
- on leaving, emit `presence.left`
- on disconnect without a clean leave, rely on timeout in application logic rather than retained presence state

If presence traffic later becomes hot enough to deserve separation, it can be split into a dedicated non-retained topic. That is an optimization, not part of the initial redesign.

## Server Responsibilities

The daemon/server side should become simpler, not smarter.

Its MQTT responsibilities are:

- route device-targeted RPC
- publish targeted notify events
- publish and consume session live events for sessions it participates in

Its non-MQTT responsibilities are:

- persist authoritative membership and session metadata to Supabase
- answer explicit catch-up/history RPCs
- maintain daemon-local session subscription set from membership truth

The daemon should not:

- maintain team-wide retained indexes on MQTT
- materialize session metadata views in broker topics
- depend on retained topics to rebuild session state

## Detailed Case Handling

### Case 1: invite another person into a session

Yes, the other person must be told, but not by broadcasting on the team or by writing session state into MQTT.

Correct path:

1. persist invite/membership in Supabase
2. send targeted `device/{device}/notify`
3. receiving device refreshes membership truth
4. when the user opens the session, the app fetches history and subscribes to `session/live`

### Case 2: user leaves and later re-enters a session

Correct path:

1. fetch session truth and recent messages from Supabase
2. establish `session/live`
3. run catch-up RPC if needed

This is acceptable and intentional. It keeps reconnect cost low and avoids retained replay complexity.

### Case 3: daemon must receive all realtime messages for sessions it was added to

The daemon is a special client type. It should keep `session/live` subscriptions for all sessions where it is an active participant.

This is still scalable because:

- subscription count grows with the daemon's real participation set
- it does not grow with total team session count
- membership truth comes from Supabase, so resubscription after reconnect is straightforward

## Migration Plan

### Phase 1: move truth off MQTT

- make Supabase or explicit RPC the only source of session list, membership, and history truth
- stop adding new MQTT retained state for Teamclaw

### Phase 2: add new channels

- add `device/{device}/notify`
- add `session/{session}/live`
- keep old topics temporarily for compatibility

### Phase 3: dual publish and dual consume

- publish session messages/tasks/presence to both old topics and new `live`
- let clients and daemon read from new channels while old paths still exist

### Phase 4: switch subscription behavior

- app clients subscribe only to foreground sessions
- daemon subscribes by active membership set
- reconnect paths fetch truth from Supabase and use catch-up RPC

### Phase 5: delete old stateful MQTT model

- remove `team/sessions`
- remove actor-scoped retained session metadata
- remove retained session indexes and retained session meta publication
- remove session topic subscriptions that accumulate without lifecycle boundaries

## Compatibility Constraints

During migration, mixed-version clients will exist. The transition needs a bounded compatibility period.

Requirements:

- new daemon should be able to publish both old and new session realtime events during rollout
- old clients may continue to consume existing session topics until app rollout finishes
- the deletion of retained session metadata must happen only after all critical consumers have moved to Supabase/RPC truth

This compatibility layer should be temporary. The redesign succeeds only if the old stateful MQTT paths are fully removed.

## Success Criteria

The redesign is successful when all of the following are true:

- reconnect cost for app clients depends only on device topics plus currently open session topics
- reconnect cost does not depend on historical session count
- daemon subscription count depends only on sessions it actively participates in
- there is no Teamclaw session retained index or retained session metadata on MQTT
- session membership and history can be fully reconstructed from Supabase plus explicit RPC
- invite fan-out is targeted by device, not broadcast by team

## Open Questions Resolved By This Spec

- Should invite flow push a message to other users? Yes, via targeted `device/notify`, not session broadcast.
- Should re-entering a session fetch from Supabase before resubscribing to realtime? Yes.
- Should daemon receive all realtime messages for sessions it participates in? Yes, by maintaining a Supabase-derived subscription set for those sessions.

## Summary

The core move is simple:

- remove MQTT-retained Teamclaw state
- collapse session realtime into one `session/live` stream
- use `device/notify` for targeted invalidation
- let app and daemon subscribe differently
- rebuild truth from Supabase and explicit RPC after reconnect

That gives Teamclaw a broker-friendly shape that scales with active work, not historical churn.
