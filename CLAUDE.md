# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

AMUX (Agent Multiplexer) is a multi-platform system for remotely monitoring and controlling AI coding agents. It has three components:

- **Rust daemon (`amuxd`)** in `daemon/` -- runs on the developer's machine, spawns and manages agent processes (Claude Code via ACP/stdio), publishes events over MQTT
- **iOS client** in `ios/` -- SwiftUI app that connects to the daemon via MQTT to monitor agents, send prompts, and handle permission requests
- **Protobuf schema** in `proto/amux.proto` -- single source of truth for all cross-platform message types

Communication flows: daemon <-> MQTT broker (HiveMQ, TLS) <-> iOS client. Messages are Protobuf-encoded, QoS 1, with sequence-numbered Envelopes for deduplication.

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

## Architecture Details

### Daemon Modules (`daemon/src/`)
- `agent/adapter.rs` -- spawns Claude Code subprocess, parses stream-json stdout into AcpEvent protos
- `agent/manager.rs` -- agent lifecycle (spawn/stop/list)
- `daemon/server.rs` -- main event loop: polls MQTT, dispatches commands to agents, publishes events
- `mqtt/` -- client (TLS connection), publisher (event->topic mapping), subscriber (topic->message parsing)
- `collab/` -- member auth (token validation), peer tracking, permissions
- `config/` -- loads `~/.config/amux/daemon.toml` and `members.toml`

### iOS Packages
- **AMUXCore** (`ios/Packages/AMUXCore/`) -- `MQTTService` (mqtt-nio wrapper), `ProtoMQTTCoder` (protobuf encode/decode), SwiftData `@Model` types (Agent, AgentEvent, Member), `PairingManager`, `ConnectionMonitor` (daemon LWT detection)
- **AMUXUI** (`ios/Packages/AMUXUI/`) -- MVVM views: SessionList, AgentDetail (event feed), Members, Settings

### MQTT Topic Structure
```
amux/{deviceId}/agents                        # AgentList (retained)
amux/{deviceId}/agent/{agentId}/events        # AcpEvent stream
amux/{deviceId}/agent/{agentId}/commands      # Client commands
amux/{deviceId}/status                        # DeviceStatus (LWT, retained)
```

### CLI Subcommands
`init`, `start`, `invite {name}`, `members [list|remove]`, `test-spawn`, `test-client [watch|start-agent|announce|e2e]`

## Key Conventions

- iOS minimum deployment: iOS 17.0, Swift 5.10
- Rust edition: 2021
- Daemon config lives at `~/.config/amux/daemon.toml`
- Commit messages use conventional commits with scope: `feat(ios):`, `fix(daemon):`, etc.
- Specs live in `docs/specs/`; plans in `docs/plans/`
