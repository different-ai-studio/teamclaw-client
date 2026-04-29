# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

AMUX (Agent Multiplexer) is a multi-platform system for remotely monitoring and controlling AI coding agents. It has three components:

- **Rust daemon (`amuxd`)** in `daemon/` -- runs on the developer's machine, spawns and manages agent processes (Claude Code via ACP/stdio), publishes events over MQTT
- **iOS client** in `ios/` -- SwiftUI app that connects to the daemon via MQTT to monitor agents, send prompts, and handle permission requests
- **Protobuf schema** in `proto/amux.proto` -- single source of truth for all cross-platform message types

Communication flows: daemon <-> MQTT broker (EMQX, TLS) <-> iOS client. Messages are Protobuf-encoded, QoS 1, with sequence-numbered Envelopes for deduplication.

## Build Commands

### Daemon (Rust)
```bash
cd daemon && cargo build          # build
cd daemon && cargo run -- start   # run daemon
cd daemon && cargo run -- init    # first-time setup
RUST_LOG=amuxd=debug cargo run -- start  # verbose logging
```

### iOS
Open `ios/AMUX.xcodeproj` in Xcode, or regenerate the project from `ios/project.yml` with XcodeGen. The app target depends on two local SPM packages: `AMUXCore` (models, MQTT, pairing) and `AMUXUI` (SwiftUI views).

### Protobuf Code Generation
```bash
# Rust: automatic via daemon/build.rs (prost-build) on cargo build
# Swift: manual
./scripts/proto-gen-swift.sh
```
Generated Swift files go to `ios/Proto/Generated/`. Always regenerate after editing `proto/amux.proto`.

## Concept Glossary

Naming is inconsistent across layers — use this as the source of truth:

| Concept | Supabase | MQTT | Daemon code |
|---------|----------|------|-------------|
| Developer machine running amuxd | `agents` row (`actor_type='agent'`) | `device_id` in topic path | `config.device` |
| Individual Claude Code subprocess | `agent_runtimes` row | `runtime/{runtime_id}` in topic path | `RuntimeHandle` |

**Key identifiers:**
- `agents.id` — Supabase UUID for the daemon identity; used as FK in `agent_runtimes.agent_id`
- `agents.device_id` — short string from `daemon.toml`; used in MQTT topic paths as `{device_id}`; stored in Supabase so iOS can resolve the daemon without knowing its UUID
- `RuntimeHandle.agent_id` — 8-char UUID generated at spawn; used in MQTT topic paths as `{runtime_id}` under the device; maps to an `agent_runtimes` row (keyed on `agents.id` + `backend_session_id`)

**Naming note:** The daemon's structural types (`RuntimeManager`, `RuntimeHandle`) and module path (`daemon/src/runtime/`) align with the Supabase `agent_runtimes` semantic, and the wire-format topic uses `runtime/{runtime_id}` to match. Local variable names like `agent_id` still appear inside `forward_agent_event` and friends as transient traces of the older naming — same conceptual id, just two different spellings.

## Architecture Details

### Daemon Modules (`daemon/src/`)
- `runtime/adapter.rs` -- spawns Claude Code subprocess, parses stream-json stdout into AcpEvent protos
- `runtime/manager.rs` -- runtime lifecycle (spawn/stop/list)
- `daemon/server.rs` -- main event loop: polls MQTT, dispatches commands to agents, publishes events
- `mqtt/` -- client (TLS connection), publisher (event->topic mapping), subscriber (topic->message parsing)
- `collab/` -- member auth (token validation), peer tracking, permissions
- `config/` -- loads `~/.config/amux/daemon.toml` and `members.toml`

### iOS Packages
- **AMUXCore** (`ios/Packages/AMUXCore/`) -- `MQTTService` (mqtt-nio wrapper), `ProtoMQTTCoder` (protobuf encode/decode), SwiftData `@Model` types (Agent, AgentEvent, Member), `PairingManager`, `ConnectionMonitor` (daemon LWT detection)
- **AMUXUI** (`ios/Packages/AMUXUI/`) -- MVVM views: SessionList, AgentDetail (event feed), Members, Settings

### MQTT Topic Structure

AMUX uses team-scoped MQTT topics with two main categories:

**Device-scoped topics** (device management, runtimes):
```
amux/{team_id}/device/{device_id}/status                        # DeviceStatus (LWT, retained)
amux/{team_id}/device/{device_id}/peers                         # PeerList (retained)
amux/{team_id}/device/{device_id}/workspaces                    # WorkspaceList (retained)
amux/{team_id}/device/{device_id}/collab                        # DeviceCollabEvent (legacy notify channel; payload type kept for wire compat)
amux/{team_id}/device/{device_id}/runtime/{runtime_id}/state    # RuntimeInfo per runtime (retained)
amux/{team_id}/device/{device_id}/runtime/{runtime_id}/events   # AcpEvent stream — legacy fallback only
amux/{team_id}/device/{device_id}/runtime/{runtime_id}/commands # Client commands
```

**Session topics** (session realtime, notifications):
```
amux/{team_id}/device/{device_id}/rpc/req                       # Teamclaw RPC requests
amux/{team_id}/device/{device_id}/rpc/res                       # Teamclaw RPC responses
amux/{team_id}/device/{device_id}/notify                        # Membership refresh / targeted notify
amux/{team_id}/session/{session_id}/live                        # Session live event stream — canonical inbound + ACP fanout
```

Runtime state is fanned out to one retained topic per runtime (not a single
`AgentList`) so no publish exceeds the broker's 10 KB packet cap. Clients
subscribe to wildcard patterns like `amux/{team_id}/device/{device_id}/runtime/+/state`
and aggregate locally.

For session-backed flow (every iOS session today), ACP events fan out to
`session/{session_id}/live` instead of `runtime/{runtime_id}/events`, so iOS
only needs the session-id it created in Supabase to follow streaming output —
no daemon device-id resolution required. The legacy per-runtime events topic
is kept as a fallback for session-less spawns; nothing in iOS subscribes to it
today.

### CLI Subcommands
`init`, `start`, `invite {name}`, `members [list|remove]`, `test-spawn`, `test-client [watch|start-agent|announce|e2e]`

## Key Conventions

- iOS minimum deployment: iOS 17.0, Swift 5.10
- Rust edition: 2021
- Daemon config lives at `~/.config/amux/daemon.toml`
- Commit messages use conventional commits with scope: `feat(ios):`, `fix(daemon):`, etc.
- Specs live in `docs/specs/`; plans in `docs/plans/`

## macOS SwiftUI gotchas

**NEVER attach `.modelContainer(...)` to a `.sheet` on macOS.** Doing so forces
SwiftUI to rebuild the window scene, which silently drops the toolbar items
from any `NavigationSplitView` column (column 2's `+ / edit / search` buttons
vanish). If a sheet needs SwiftData rows, query them in the parent view and
pass the plain array into the sheet as a parameter — do **not** use `@Query`
inside the sheet and do **not** re-inject a modelContainer. Confirmed
regression during the per-agent retained-state refactor (2026-04-20); see
`MainWindowView.swift` → `NewSessionSheet(workspaces: ...)` for the working
pattern.
