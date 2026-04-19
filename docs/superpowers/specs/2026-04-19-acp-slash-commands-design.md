# ACP Slash Command Discovery — Design

**Date:** 2026-04-19
**Status:** Approved (brainstorm phase complete)

## Problem

Slash commands like `/clear`, `/compact`, `/model` currently work end-to-end only because they're forwarded as plain text inside `AcpSendPrompt.text` and the Claude Code wrapper happens to recognize them. Three gaps follow from this:

1. **Zero discovery on iOS.** The client has no idea which slash commands exist for the currently-attached agent. Users must memorize them from the terminal.
2. **No autocomplete UX.** Typing `/` in the composer is treated like any other character. There is no way to surface available commands, their descriptions, or required arguments.
3. **No multi-agent story.** Every future agent (OpenCode, Codex, custom wrappers) would face the same discovery gap. There is no protocol path for announcing commands.

ACP v0.11 (schema crate, already transitively pulled in by `agent-client-protocol = 0.10.4` via `pub use`) ships a first-class `SessionUpdate::AvailableCommandsUpdate` notification. Daemon's adapter currently drops that variant in its catch-all `_ => {}` arm. Wiring it through is the cheapest path to native discovery on any ACP agent.

## Goals

- Wire `SessionUpdate::AvailableCommandsUpdate` from the ACP adapter out over MQTT to iOS as a new `AcpEvent` variant.
- Store the pushed command list in-memory per session on iOS.
- In the iOS composer: detect `/` prefix → show an inline autocomplete popup filtered by prefix → tap inserts `"/name "` and visually emphasizes the send button.
- Gracefully no-op when the wrapper never pushes a command list (current behavior preserved).

## Non-Goals (Explicitly Deferred)

- **Hardcoded fallback table per `AgentType`.** Rejected in favor of pure push. If a wrapper never pushes, autocomplete never appears and users still type `/clear` as text. Simpler, protocol-driven.
- **Mac client.** `mac/Packages/AMUXMacUI` also has a composer; out of scope this iteration. Daemon + proto changes are shared and don't block mac from catching up later.
- **Local side effects.** `/clear` will *not* clear iOS SwiftData history, `/cost` will *not* render a special card. Every command is pass-through text. Local semantics can be layered on later per-command.
- **AMUX-specific commands.** No amux-injected `/amux-*` entries. Only what the agent announces.
- **SwiftData persistence of commands.** Commands are ambient per-session state, not history. Lost on app restart until next push — matches ACP push semantics.
- **Keyboard up/down arrow navigation in the popup.** Tap-only in v1. External-keyboard support is a follow-up.
- **ACP crate version bump.** `agent-client-protocol = 0.10.4` is the latest publish on crates.io and already re-exports schema 0.11.4's `AvailableCommandsUpdate`. Pin will be loosened from `= "0.10.4"` to `"0.10"` to auto-pick up patches, but no feature bump is required.

## Architecture

```
Claude Code (ACP wrapper, stdio JSON-RPC)
  ↓ session/update { sessionUpdate: "available_commands_update", availableCommands: [...] }
daemon/src/agent/adapter.rs :: translate_session_update
  ↓ new branch → amux::AcpEvent { event: Some(AvailableCommands(AcpAvailableCommands { ... })) }
daemon/src/daemon/server.rs (existing AcpEvent publisher, zero change)
  ↓ MQTT publish (QoS 1, not retained) → amux/{deviceId}/agent/{agentId}/events
iOS MQTTService → ProtoMQTTCoder → AgentDetailViewModel
  ↓ new case in event dispatch → availableCommands: [SlashCommand] (in-memory, replace whole list)
AgentDetailView composer
  ↓ onChange(composerText): matches /^\/([a-z0-9_-]*)$/ → filter → slashCandidates
  ↓ SlashCommandsPopup (new overlay, above composer)
  ↓ tap candidate → composerText = "/\(name) "; hasPendingSlashCommand = true
  ↓ send button tint emphasized until send or composer no longer matches known command
  ↓ user taps send → existing TeamclawService.sendPrompt path (zero change)
```

Send path is untouched — slash commands still traverse the daemon as plain-text `AcpSendPrompt`. The wrapper does the work of recognizing `/clear` et al. The send-button emphasis is a visual cue, not a new transport.

## Components

### 1. Proto — `proto/amux.proto`

Add two messages and wire one new variant into the existing `AcpEvent.event` oneof:

```proto
message AcpAvailableCommand {
  string name = 1;              // e.g. "clear", "compact"
  string description = 2;       // human-readable
  string input_hint = 3;        // "" = no input; non-empty = hint for unstructured arg
}

message AcpAvailableCommands {
  repeated AcpAvailableCommand commands = 1;
}

// Inside AcpEvent.event oneof, add:
//   AcpAvailableCommands available_commands = N;
// (N = next unused tag after current variants)
```

`input_hint` uses empty-string sentinel instead of a wrapped optional to keep the iOS decoding trivial. Agent → client only; no new client → agent command.

### 2. Daemon — `daemon/src/agent/adapter.rs`

Inside `translate_session_update`'s match, insert a branch **before** the catch-all `_ => { debug!("unhandled"); vec![] }`:

```rust
acp::SessionUpdate::AvailableCommandsUpdate(upd) => {
    let commands = upd.available_commands.into_iter().map(|c| {
        let input_hint = match c.input {
            Some(acp::AvailableCommandInput::Unstructured(u)) => u.hint,
            _ => String::new(),
        };
        amux::AcpAvailableCommand {
            name: c.name,
            description: c.description,
            input_hint,
        }
    }).collect();
    vec![amux::AcpEvent {
        event: Some(amux::acp_event::Event::AvailableCommands(
            amux::AcpAvailableCommands { commands },
        )),
        model: String::new(),
    }]
}
```

Validation is light: empty names are tolerated here — iOS filters them at render time. Defensive skipping at the daemon would mask misbehaving wrappers; better to let the event through so debug logs can see it.

### 3. Daemon — `Cargo.toml`

Loosen `agent-client-protocol = { version = "0.10.4", features = [...] }` to `"0.10"` to auto-track patches. Optional; purely hygienic. Does not change feature flags or the schema-crate version.

### 4. iOS — `AgentDetailViewModel`

New type + state + event handler:

```swift
struct SlashCommand: Identifiable, Equatable, Hashable {
    let name: String
    let description: String
    let inputHint: String   // "" = no input
    var id: String { name }
}

@Published var availableCommands: [SlashCommand] = []
```

In the existing `AcpEvent` dispatch switch (wherever `AgentMessageChunk`, `ToolUse`, etc. are handled), add:

```swift
case .availableCommands(let upd):
    availableCommands = upd.commands
        .filter { !$0.name.isEmpty }
        .map { SlashCommand(name: $0.name,
                            description: $0.description,
                            inputHint: $0.inputHint) }
```

Full replacement on every push (ACP semantics — `AvailableCommandsUpdate` is always a complete list). No SwiftData, no persistence. Each `AgentDetailViewModel` instance owns its own list → session isolation is automatic.

Do **not** clear `availableCommands` on session end. The agent will push a fresh list when the next session starts; keeping the old one until then is harmless (popup won't open without user invocation).

### 5. iOS — `SlashCommandsPopup` (new file)

`ios/Packages/AMUXUI/Sources/AMUXUI/AgentDetail/SlashCommandsPopup.swift`

A SwiftUI view:

- Inputs: `candidates: [SlashCommand]`, `onTap: (SlashCommand) -> Void`
- Layout: vertical stack / `List`, caps at ~5 visible rows (scrolls if more); each row shows `Text("/\(cmd.name)")` in a mono or semibold font followed by `Text(cmd.description)` in `.secondary` foreground, single-line, truncating.
- Appearance: rounded-corner material background (`.regularMaterial`), subtle shadow, ~280pt max width, anchored to the composer's top edge.
- Rendered only when `!candidates.isEmpty`.

### 6. iOS — `AgentDetailView` composer wiring

New `@State` alongside the existing composer state:

```swift
@State private var slashCandidates: [SlashCommand] = []
@State private var hasPendingSlashCommand: Bool = false
```

Behavior (added to existing composer):

- `onChange(of: composerText)`:
  1. If regex `^/([a-zA-Z0-9_-]*)$` matches, take the captured prefix and filter `viewModel.availableCommands` where `name.hasPrefix(prefix)` (case-insensitive). Assign to `slashCandidates`.
  2. Otherwise, `slashCandidates = []`.
  3. Update `hasPendingSlashCommand`: true iff `composerText` currently starts with `/<knownName>` followed by space or end-of-string. Recompute from scratch each time so deletions downgrade the flag.

- Tap handler for popup row: `composerText = "/\(cmd.name) "`, `slashCandidates = []`, `hasPendingSlashCommand = true`. If `cmd.inputHint` is non-empty, show the hint as secondary-color placeholder text under the composer until the user begins typing the argument (disappears once `composerText.count > "/\(name) ".count`).

- Send button styling: `.foregroundStyle(hasPendingSlashCommand ? Color.accentColor : Color.secondary)` (or equivalent emphasis via existing design tokens). Reset `hasPendingSlashCommand = false` immediately after invoking send.

- Overlay placement: render `SlashCommandsPopup(candidates: slashCandidates, onTap: ...)` as an `.overlay(alignment: .bottom)` on the message-list scroll view, above the composer. Animate in/out with `.transition(.opacity.combined(with: .move(edge: .bottom)))`.

Send action is **unchanged** — still `teamclawService.sendPrompt(composerText)`. Slash handling happens entirely at the wrapper.

## Data Flow

**Discovery (agent → iOS):**
1. Session starts; Claude Code wrapper pushes `session/update { sessionUpdate: "available_commands_update", availableCommands: [...] }` (timing is wrapper-dependent, typically shortly after initialize or after first prompt).
2. Adapter translates → `amux::AcpEvent::AvailableCommands(...)`.
3. server.rs publishes over existing AcpEvent path, QoS 1, **not retained**.
4. iOS decodes → `AgentDetailViewModel.availableCommands` replaced wholesale.

**Use (iOS local):**
1. User types in composer. `onChange` fires.
2. Regex matches → filter → `slashCandidates` populated → popup appears.
3. Tap → insert `"/name "` + set `hasPendingSlashCommand` + popup dismisses.
4. If `inputHint` non-empty, hint shows as placeholder below composer.
5. Send button is accent-colored. User taps send → normal send path.

**Non-retained consequence:** Reconnecting MQTT does not replay the commands list. iOS keeps the last cached list in `AgentDetailViewModel` until the wrapper pushes again (typical on resume).

## Error Handling

- **Wrapper never pushes `AvailableCommandsUpdate`:** `availableCommands` stays empty; popup never appears; `/clear` typed by hand still sends as text. Silent, graceful.
- **Empty array pushed:** Cache cleared. Popup won't appear. Legitimate "no commands available" state.
- **Malformed entry (empty name):** iOS filters at render time. Daemon passes through unchanged for log visibility.
- **Push lands after user opened popup:** Next `onChange` cycle (or re-opening) uses the fresh list. User-perceived worst case: one stale popup frame.
- **Composer regex edge cases** (`/ `, `//`, `/中文`, `/_foo-bar`): regex only accepts `[a-zA-Z0-9_-]*`. Non-matching inputs → popup hidden → text sent as-is.
- **MQTT disconnect during session:** Old cache retained. User can still tap through popup (sends as plain text; wrapper handles it on reconnect).

There is no user-facing error surface. Every failure mode degrades to the current "`/clear` is just text" behavior.

## Testing

Manual smoke on simulator:

1. **Happy path:** Launch a Claude Code session → wait a few seconds → type `/` in composer → popup appears with wrapper-announced commands (Claude's default set should include at least `/clear`, `/compact`). Tap `/clear` → composer shows `/clear `, send button highlighted. Tap send → Claude Code acts on the command (clear/compact/etc. per wrapper's behavior).
2. **Command with input:** If any announced command has `inputHint` (e.g. `/rename <new name>`), tap it → composer holds `/rename ` with hint visible as placeholder. Type argument → hint disappears → send.
3. **Prefix filter:** Type `/cl` → only commands starting with `cl` remain. Type `/xyz` (no match) → popup hidden.
4. **Degraded mode:** Temporarily stub `translate_session_update` to drop AvailableCommandsUpdate → iOS `availableCommands` stays empty → typing `/clear` works via plain text (no popup, no emphasis, but send still reaches wrapper).
5. **Session isolation:** Open session A, confirm its commands; switch to session B, confirm it has its own list (or empty until B's wrapper pushes).
6. **MQTT reconnect:** Disable Wi-Fi for ~5s, re-enable → existing cache survives; popup still opens; new push (if wrapper re-announces on resume) replaces the list.

Rust unit test in `daemon/src/agent/adapter.rs`:

```rust
#[test]
fn translates_available_commands_update() {
    // Build an acp::SessionUpdate::AvailableCommandsUpdate with two commands
    // (one with Unstructured input, one without) and assert the resulting
    // amux::AcpEvent carries the correct names, descriptions, and input_hint
    // strings ("" for the one without input).
}
```

No iOS unit tests — matches existing iOS convention in this repo (manual smoke only).

## Migration Map (files changed)

- **Modify:** `proto/amux.proto` — add `AcpAvailableCommand`, `AcpAvailableCommands`; add variant to `AcpEvent.event` oneof.
- **Run:** `./scripts/proto-gen-swift.sh` — regenerate Swift proto. Rust side auto-regenerates via `daemon/build.rs`.
- **Modify:** `daemon/Cargo.toml` — relax `agent-client-protocol` version pin from `= "0.10.4"` to `"0.10"` (optional hygiene).
- **Modify:** `daemon/src/agent/adapter.rs` — new branch in `translate_session_update` for `AvailableCommandsUpdate`; add one unit test.
- **Modify:** `ios/Packages/AMUXUI/Sources/AMUXUI/AgentDetail/AgentDetailViewModel.swift` — `SlashCommand` struct, `availableCommands` state, event dispatch case.
- **Create:** `ios/Packages/AMUXUI/Sources/AMUXUI/AgentDetail/SlashCommandsPopup.swift` — popup view.
- **Modify:** `ios/Packages/AMUXUI/Sources/AMUXUI/AgentDetail/AgentDetailView.swift` — composer `onChange`, popup overlay, send-button emphasis.

No MQTT topic changes. No daemon RPC changes. No SwiftData migration. No XcodeGen regen. No mac changes.
