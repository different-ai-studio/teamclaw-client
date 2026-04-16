# AMUX — Agent Multiplexer

AMUX is a multi-platform system for remotely monitoring and controlling AI coding agents. A Rust daemon runs on the developer's machine, managing agent processes and publishing events over MQTT. An iOS client connects to the daemon for real-time monitoring, prompt input, and permission handling.

AMUX 是一个多平台系统，用于远程监控和操控 AI 编程代理。Rust 守护进程运行在开发者机器上，管理代理进程并通过 MQTT 发布事件。iOS 客户端连接守护进程，实现实时监控、发送提示词和处理权限请求。

## Features / 功能

- **Daemon (`amuxd`)** — Rust daemon that spawns and manages AI coding agents via ACP/stdio
- **iOS Client** — SwiftUI app for real-time agent monitoring and control
- **Protobuf Schema** — Single source of truth for all cross-platform message types
- **MQTT Communication** — TLS-encrypted, QoS 1, with sequence-numbered envelopes

## Architecture / 架构

```text
┌─────────────┐     MQTT (TLS)     ┌─────────────┐
│  Rust Daemon │ ◄═══════════════► │  iOS Client  │
│   (amuxd)    │                    │  (SwiftUI)   │
└──────┬───────┘                    └──────────────┘
       │
  proto/amux.proto
  (shared schema)
```

## Prerequisites / 前置条件

- Rust (edition 2021)
- Xcode 15+ (iOS 17.0, Swift 5.10)
- Protocol Buffers compiler (`protoc`)
- An MQTT broker with TLS support

## Getting Started / 快速开始

### Daemon

```bash
cd daemon
cargo build
cargo run -- init    # first-time setup / 首次配置
cargo run -- start   # run daemon / 启动守护进程
```

### iOS

Open `ios/AMUX.xcodeproj` in Xcode, or regenerate from `ios/project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen).

### Protobuf Code Generation / 代码生成

```bash
# Rust: automatic via daemon/build.rs
# Swift:
./scripts/proto-gen-swift.sh
```

## Configuration / 配置

- Daemon config: `~/.config/amux/daemon.toml`
- Member management: `~/.config/amux/members.toml`

See `cargo run -- --help` for all CLI subcommands.

## License / 许可证

[MIT](LICENSE)
