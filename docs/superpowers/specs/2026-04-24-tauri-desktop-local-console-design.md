# Tauri Desktop Local Console — Design Spec

**Status**: direction approved; pending written-spec review
**Date**: 2026-04-24
**Scope**: future Tauri desktop client architecture, local amuxd control, protocol shape that preserves remote daemon control later

## Goal

Build the future Tauri desktop app as a local-first `amuxd` control console while keeping the client architecture compatible with remote daemon control.

The first shipped desktop version should optimize for the common case:

```text
Tauri desktop and amuxd run on the same machine.
```

The architecture must still preserve AMUX's existing distributed model:

```text
iOS / desktop clients -> amuxd -> ACP agent runtime
                      -> MQTT realtime
                      -> Supabase durable truth
```

Desktop must not become a second runtime host, a parallel state store, or a peer-to-peer sync partner for iOS.

## Non-Goals

- Implementing remote daemon control in the first Tauri release.
- Designing a new desktop-only session model.
- Letting the Tauri app directly manage ACP subprocesses.
- Desktop-to-iOS direct synchronization.
- Multi-daemon aggregation UI.
- Replacing MQTT or Supabase as the cross-device synchronization mechanisms.
- Rewriting existing iOS/mac Swift UI architecture.

## Decision

Use a **hybrid local-first client architecture**.

The desktop app owns UI, daemon lifecycle assistance, and local operator ergonomics. `amuxd` remains the sole owner of runtime processes, workspace registration, ACP lifecycle, session writes, task writes, and outbound sync.

```text
Tauri UI
  -> Desktop Client Core
      -> LocalTransport       # v1 default, connects to local amuxd
      -> RemoteTransport      # future, same client API over MQTT/Supabase
  -> amuxd local control API
      -> daemon core handlers
      -> ACP runtime
      -> MQTT/Supabase sync
```

The UI talks to a transport-neutral client API. Version 1 only implements `LocalTransport`, but the API shape remains compatible with `RemoteTransport`.

## Approaches Considered

### Option A: Local-only desktop

Desktop speaks only to a local daemon through local IPC.

This is simple and fast, but it creates a product trap: UI and data contracts drift away from iOS, remote daemon control becomes a rewrite, and iOS visibility depends on every local mutation being manually mirrored.

Rejected as the primary architecture.

### Option B: MQTT-only desktop

Desktop behaves exactly like iOS, even when controlling the daemon on the same machine.

This keeps one network contract, but it makes desktop worse at things only a local app can do: daemon discovery, daemon startup, diagnostics, local config editing, and low-latency local event streaming.

Rejected for v1 ergonomics.

### Option C: Hybrid local-first

Desktop uses a local transport for the colocated daemon, while preserving the same command semantics as the MQTT/Supabase path.

This is the recommended approach. It gives the desktop app native control over the local daemon lifecycle without forking the product model.

## Architectural Invariants

1. `amuxd` is the runtime owner.
   The Tauri app never spawns, stops, or talks to ACP runtimes directly.

2. All business writes go through daemon handlers.
   LocalTransport may skip the MQTT hop, but it must not skip daemon validation, persistence, event publication, or Supabase sync.

3. Local and remote semantics are equivalent.
   A local `startRuntime` returns the same kind of accepted/rejected result as MQTT `RuntimeStart`. Completion is observed through runtime state transitions.

4. iOS and desktop sync through AMUX infrastructure, not through each other.
   Desktop writes are visible to iOS because `amuxd` publishes MQTT events and writes Supabase truth.

5. UI code does not know whether the transport is local or remote.
   The transport selection layer can prefer local today and remote later without changing view logic.

6. `device_id`, `team_id`, `actor_id`, `runtime_id`, `session_id`, and `workspace_id` remain first-class IDs in the desktop API.
   Even local-only v1 must keep these fields so the remote path is not designed later as an afterthought.

## Product Scope: V1

The first Tauri desktop release should include:

- local `amuxd` discovery
- local `amuxd` start/stop/restart assistance
- daemon connection health and logs
- workspace list and workspace registration
- session list, task list, and session detail
- runtime list and runtime detail
- start/stop runtime
- send prompt / session message
- runtime state and event streaming
- permission request handling
- model selection where the daemon/runtime supports it
- pairing/config visibility sufficient to explain what iOS is connected to

V1 should not include:

- selecting a remote daemon from another machine
- cross-team switching beyond what current config already supports
- multi-daemon dashboards
- desktop-originated APNs or mobile push behavior
- direct writes to Supabase from the UI for session/task/runtime mutations

## Desktop Client API

The client core exposes product operations, not transport details.

```ts
interface AmuxClientTransport {
  connect(target: DaemonTarget): Promise<void>
  disconnect(): Promise<void>

  fetchDeviceState(): Promise<DeviceState>
  fetchWorkspaces(): Promise<Workspace[]>
  fetchSessions(input: SessionQuery): Promise<SessionPage>
  fetchTasks(input: TaskQuery): Promise<TaskPage>
  fetchSessionMessages(input: MessageQuery): Promise<MessagePage>

  startRuntime(input: RuntimeStartInput): Promise<RuntimeStartAccepted>
  stopRuntime(runtimeId: string): Promise<RuntimeStopAccepted>

  createSession(input: CreateSessionInput): Promise<Session>
  createTask(input: CreateTaskInput): Promise<Task>
  updateTask(input: UpdateTaskInput): Promise<Task>
  sendSessionMessage(input: SendSessionMessageInput): Promise<void>

  subscribeDeviceState(handler: (state: DeviceState) => void): Unsubscribe
  subscribeRuntimeState(handler: (state: RuntimeInfo) => void): Unsubscribe
  subscribeRuntimeEvents(runtimeId: string, handler: (event: RuntimeEvent) => void): Unsubscribe
  subscribeSessionLive(sessionId: string, handler: (event: LiveEvent) => void): Unsubscribe
  subscribeNotify(handler: (event: Notify) => void): Unsubscribe
}
```

This interface is intentionally close to existing MQTT and Teamclaw concepts:

- `startRuntime` matches `RuntimeStartRequest` accepted-only semantics.
- `runtimeState` mirrors `device/{device}/runtime/{runtime}/state`.
- `runtimeEvents` mirrors `device/{device}/runtime/{runtime}/events`.
- `sessionLive` mirrors `amux/{team}/session/{session}/live`.
- `notify` remains an invalidation hint, not a state payload.

## LocalTransport

`LocalTransport` is the only v1 transport.

Preferred shape:

```text
Tauri Rust backend
  -> local amuxd control client
      -> Unix domain socket on macOS/Linux
      -> named pipe or localhost fallback where needed
```

The Tauri web UI should not open the socket directly. The Tauri Rust backend owns local process access and exposes typed Tauri commands/events to the frontend.

### Local endpoint

`amuxd` should expose one local control endpoint while running:

```text
macOS/Linux: $AMUX_CONFIG_DIR/amuxd.sock
fallback:    127.0.0.1:<ephemeral-or-configured-port>
```

The endpoint is local-machine only. It must not bind to a public interface.

### Wire format

Use structured request/response envelopes with protobuf-backed payloads where practical.

The local endpoint does not need to reuse MQTT topics, but it should reuse the same domain messages and response semantics. For example:

```text
Local request:  RuntimeStartRequest
Local reply:    RuntimeStartResult { accepted, runtime_id, session_id, rejected_reason }
State stream:   RuntimeInfo updates
```

This avoids inventing a desktop-only protocol while still allowing local multiplexing over a single socket.

### Event streaming

LocalTransport should multiplex these streams:

- device state
- runtime state wildcard
- runtime events for selected runtimes
- session live for foreground sessions
- notify hints
- daemon log tail

Foreground subscription lifecycle should match the MQTT design:

- session live is subscribed only for open sessions
- runtime events are subscribed only for visible runtime detail views
- runtime state can be wildcarded for the paired local daemon

## RemoteTransport (Future)

`RemoteTransport` is not in v1, but the client API must support it.

Future mapping:

```text
fetch sessions/tasks/messages  -> Supabase reads or daemon RPC where currently required
start/stop runtime             -> device/{daemon}/rpc/req|res
runtime state                  -> device/{daemon}/runtime/+/state
runtime events                 -> device/{daemon}/runtime/{runtime}/events
runtime commands               -> device/{daemon}/runtime/{runtime}/commands
session live                   -> session/{session}/live
notify                         -> device/{daemon}/notify and user/{actor}/notify
```

The remote transport uses the same `DaemonTarget` fields as LocalTransport:

```ts
type DaemonTarget = {
  mode: "local" | "remote"
  teamId: string
  deviceId: string
  actorId: string
  clientId: string
}
```

V1 can always select `mode: "local"`, but the rest of the fields should already exist in state and logs.

## amuxd Local Control API

The daemon should avoid maintaining two independent command stacks.

Recommended implementation shape:

```text
daemon core command handlers
  <- MQTT RPC adapter
  <- local control API adapter
```

The adapters decode transport-specific envelopes and call shared daemon command handlers.

Initial local API groups:

### Daemon management

- get daemon status
- get effective config
- stream daemon logs
- request graceful shutdown
- request config reload if supported

### Workspaces

- fetch workspaces
- add workspace
- remove workspace

### Sessions and tasks

- create session
- fetch session
- fetch session messages
- create task
- update task
- archive/unarchive task

### Runtime lifecycle

- start runtime
- stop runtime
- fetch runtime snapshot
- subscribe runtime state
- subscribe runtime events
- send runtime command

### Permissions

- list pending permission requests
- grant permission
- deny permission

## Daemon Supervision

Desktop can provide daemon lifecycle UX, but only outside the product command plane.

State machine:

| State | Meaning |
|---|---|
| `missing` | no configured or bundled daemon binary found |
| `stopped` | daemon binary exists but endpoint is unavailable |
| `starting` | desktop started the daemon and waits for socket readiness |
| `connected` | local endpoint is reachable and authenticated |
| `degraded` | endpoint reachable but one dependency is unhealthy |
| `error` | daemon failed to start or rejected the client |

Rules:

- Desktop may start `amuxd` as a child process or through an installed service.
- Desktop must not silently initialize a team or overwrite daemon config.
- If daemon config is missing, desktop shows onboarding and asks the user to initialize or import an invite.
- Once connected, all product operations go through the local control API.

## Data Flow

### Start runtime from desktop

1. User clicks start in Tauri UI.
2. Desktop client calls `startRuntime`.
3. LocalTransport sends `RuntimeStartRequest` to local `amuxd`.
4. Daemon validates workspace/session/model and allocates `runtime_id`.
5. Daemon replies with accepted/rejected result.
6. Daemon publishes local `RuntimeInfo { state: STARTING }`.
7. Daemon starts ACP runtime and progresses through lifecycle states.
8. Daemon publishes local runtime state and mirrors MQTT runtime state.
9. iOS sees the same runtime state through MQTT.

### Send message to session

1. Desktop sends `SendSessionMessageInput`.
2. Daemon persists the message in its session/message store and any configured durable backend.
3. Daemon emits `session/{session}/live` equivalent locally.
4. Daemon publishes MQTT `session/{session}/live`.
5. Open desktop and iOS clients update from the same event semantics.

### Reconnect desktop

1. Desktop reconnects to local socket.
2. It fetches current device/workspace/session/task/runtime snapshots.
3. It re-establishes foreground session and runtime event subscriptions.
4. It treats local stream gaps the same way MQTT does: explicit fetch first, then live stream.

## Persistence and Source of Truth

Desktop local cache is a UI cache only.

Source of truth:

| Data | Owner |
|---|---|
| runtime process lifecycle | `amuxd` |
| current runtime state | `amuxd`, mirrored to MQTT retained runtime state |
| session/task/message durable truth | Supabase and daemon stores according to current migration phase |
| workspace registration | `amuxd` plus Supabase where configured |
| actor/team membership | Supabase |
| local daemon config | `amuxd` config files |

The desktop app may cache data for fast rendering, but every reconnect starts with explicit fetch/reconcile.

## Security

LocalTransport must assume that local malware is out of scope but same-machine accidental access is in scope.

Minimum requirements:

- local socket file lives under the user's AMUX config/runtime directory
- socket permissions are user-only
- localhost fallback binds only to `127.0.0.1`
- local API requires a short-lived local auth token or file-permission proof
- no secrets are sent to the frontend unless needed for display or user action
- logs redact broker passwords, Supabase tokens, and auth tokens

RemoteTransport later must reuse the MQTT/Supabase auth model and broker ACL decisions from the MQTT topic redesign.

## Error Handling

Transport-level errors should be normalized before reaching UI:

| Error | UI behavior |
|---|---|
| daemon unavailable | show disconnected state and daemon start action |
| daemon starting | show progress and disable duplicate start |
| request rejected | show daemon-provided rejected reason |
| runtime failed after accept | show runtime `FAILED` state from state stream |
| stream gap | fetch latest snapshot and resume stream |
| unauthorized | ask user to repair pairing/config |
| version mismatch | show required daemon/app version relationship |

Slow operations follow accepted-only semantics. The UI must not wait synchronously for runtime spawn, workspace indexing, or long-running subprocess setup.

## Versioning

Desktop and daemon need an explicit local API version handshake:

```text
desktop -> daemon: Hello { client_version, supported_api_versions }
daemon  -> desktop: HelloAck { daemon_version, selected_api_version, capabilities }
```

Capabilities should drive feature visibility:

- runtime lifecycle
- session live
- task CRUD
- workspace management
- permission actions
- model selection
- log streaming
- remote-ready identity fields

This avoids hardcoding UI assumptions to one daemon build.

## Testing Strategy

### Unit tests

- transport-neutral client API maps operations to expected request envelopes
- local error normalization
- daemon lifecycle state transitions
- capability-gated feature visibility

### Daemon tests

- local API adapter and MQTT RPC adapter call the same command handlers
- `RuntimeStartRequest` returns accepted before completion
- local stream receives the same runtime state transitions as MQTT publish path
- session live local stream and MQTT publish use equivalent envelopes

### Integration tests

- start test daemon, connect LocalTransport, start runtime with a fake adapter
- send session message and verify local stream plus MQTT publish mock
- daemon restart causes desktop to fetch snapshots and resubscribe
- permission grant/deny through local API reaches the runtime manager

### Manual QA

- launch desktop with daemon stopped
- launch desktop with daemon already running
- start runtime and watch state progression
- open iOS simultaneously and verify runtime/session changes appear
- disconnect/restart daemon and verify desktop recovery
- inspect logs for secret redaction

## Migration Plan Outline

This design is not an implementation plan, but the likely sequence is:

1. Extract daemon command handlers behind transport-neutral Rust interfaces.
2. Add `amuxd` local control endpoint and API version handshake.
3. Add Tauri shell with daemon discovery and connection status.
4. Implement `LocalTransport` in Tauri Rust backend.
5. Build session/task/runtime UI against transport-neutral client API.
6. Wire local event streams and foreground subscription lifecycle.
7. Add daemon supervision UX.
8. Add tests proving local API and MQTT RPC share semantics.
9. Leave `RemoteTransport` as a compile-time-empty adapter with typed interfaces and explicit unsupported errors.

## Deferred Decisions With Defaults

These defaults are part of the design unless a later implementation plan changes them explicitly.

1. Local endpoint: use a Unix domain socket on macOS/Linux for production. Keep a localhost fallback behind a development/config flag.
2. Daemon binary: support both bundled sidecar and separately installed daemon. Prefer an already-running compatible daemon, then an installed daemon, then the bundled sidecar.
3. Store ownership: follow the active migration state at implementation time, but keep the desktop API source-of-truth-neutral. Desktop never writes around `amuxd`.
4. Log retention: stream live daemon logs and keep a small in-memory ring buffer in desktop. Durable log storage remains daemon-owned.

These defaults preserve the core decision: desktop is a local-first control console, and `amuxd` remains the runtime and sync authority.
