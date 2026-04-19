# ACP Slash Command Discovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire ACP's `AvailableCommandsUpdate` session event through daemon → MQTT → iOS, then surface the announced commands as an inline autocomplete popup in the iOS composer.

**Architecture:** Pure push — agent (via its ACP wrapper) tells daemon which slash commands exist; daemon forwards as a new `AcpEvent` variant; iOS caches the list in-memory per `AgentDetailViewModel`; composer detects `/` prefix, shows overlay, tap inserts `"/name "` and emphasizes the send button. Send path itself is unchanged (slash command text flows through existing `send_prompt`).

**Tech Stack:** Protobuf (prost + swift-protobuf), Rust (daemon/tokio/`agent-client-protocol` 0.10.4 re-exporting schema 0.11.4), SwiftUI (iOS 17+, @Observable view model), MQTT (mqtt-nio).

**Known gotcha:** SourceKit in Xcode may flash "No such module 'AMUXCore'" false positives after editing Swift files. `xcodebuild` is authoritative — if it builds, the error is spurious.

---

## File Structure

New or touched, grouped by responsibility:

- `proto/amux.proto` — add 2 messages + 1 oneof variant. Single source of truth.
- `daemon/src/agent/adapter.rs` — new match arm in `translate_session_update`; new `#[cfg(test)] mod tests` with one unit test.
- `ios/Packages/AMUXCore/Sources/AMUXCore/ViewModels/AgentDetailViewModel.swift` — new `SlashCommand` struct, new `@Observable` property `availableCommands`, new case in `handleAcpEvent`.
- `ios/Packages/AMUXUI/Sources/AMUXUI/AgentDetail/SlashCommandsPopup.swift` — new SwiftUI view (stateless presentation).
- `ios/Packages/AMUXUI/Sources/AMUXUI/AgentDetail/AgentDetailView.swift` — modify private `ReplySheet`: filter state, overlay, tap handler, send-button emphasis. Thread `availableCommands` down from the parent view.

Splits aligned with existing patterns: model + view model state live in AMUXCore; presentation lives in AMUXUI; proto lives at the repo root.

---

## Task 1: Proto — add AvailableCommands messages

**Files:**
- Modify: `proto/amux.proto`
- Generated (do not edit by hand, but verify exist after): `ios/Packages/AMUXCore/Sources/AMUXCore/Proto/amux.pb.swift`, `daemon/src/proto/amux.rs` (auto via `build.rs`)

- [ ] **Step 1: Read current AcpEvent oneof tags**

Run: `grep -n "AcpEvent\|oneof event" proto/amux.proto | head`
Confirm `AcpEvent.event` oneof currently uses tags `1..=8` and `15`. Next free tag for the new variant is `9`.

- [ ] **Step 2: Add the two messages and wire the oneof variant**

Edit `proto/amux.proto`. Immediately **after** the existing `AcpTodoItem` / `AcpTodoUpdate` block (search for `message AcpTodoUpdate`), append:

```proto
message AcpAvailableCommand {
  string name = 1;              // e.g. "clear", "compact"
  string description = 2;       // human-readable
  string input_hint = 3;        // "" = no input; non-empty = hint for unstructured arg
}

message AcpAvailableCommands {
  repeated AcpAvailableCommand commands = 1;
}
```

Then **inside** the existing `AcpEvent.event` oneof (currently containing `thinking = 1` … `todo_update = 8` … `raw = 15`), add a new line before the `raw = 15` catch-all:

```proto
    AcpAvailableCommands available_commands = 9;
```

(Keep existing `raw = 15` and `string model = 16;` untouched.)

- [ ] **Step 3: Rebuild daemon to regenerate Rust proto bindings**

Run: `cd daemon && cargo build 2>&1 | tail -20`
Expected: BUILD SUCCEEDED. prost-build picks up the new messages automatically via `build.rs`. Warnings about unused variants are OK.

- [ ] **Step 4: Regenerate Swift proto bindings**

Run: `./scripts/proto-gen-swift.sh`
Expected output: `✓ Swift proto generated in .../AMUXCore/Sources/AMUXCore/Proto`

- [ ] **Step 5: Verify Swift types landed**

Run: `grep -n "AcpAvailableCommand\|availableCommands" ios/Packages/AMUXCore/Sources/AMUXCore/Proto/amux.pb.swift | head`
Expected: matches for `struct Amux_AcpAvailableCommand`, `struct Amux_AcpAvailableCommands`, and a `case availableCommands(Amux_AcpAvailableCommands)` variant inside `OneOf_Event`.

- [ ] **Step 6: Commit**

```bash
git add proto/amux.proto ios/Packages/AMUXCore/Sources/AMUXCore/Proto/amux.pb.swift
git commit -m "feat(proto): add AcpAvailableCommands for ACP slash command discovery"
```

---

## Task 2: Daemon adapter — translate AvailableCommandsUpdate + unit test

**Files:**
- Modify: `daemon/src/agent/adapter.rs:203-330` (inside `translate_session_update` match) and append a `#[cfg(test)] mod tests` at end-of-file.

- [ ] **Step 1: Write the failing unit test**

Append to the end of `daemon/src/agent/adapter.rs`:

```rust
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn translates_available_commands_update_without_input() {
        let upd = acp::AvailableCommandsUpdate::new(vec![
            acp::AvailableCommand::new("clear", "Clear history"),
        ]);
        let events = translate_session_update(acp::SessionUpdate::AvailableCommandsUpdate(upd));

        assert_eq!(events.len(), 1);
        match events[0].event.as_ref().expect("event") {
            amux::acp_event::Event::AvailableCommands(ac) => {
                assert_eq!(ac.commands.len(), 1);
                assert_eq!(ac.commands[0].name, "clear");
                assert_eq!(ac.commands[0].description, "Clear history");
                assert_eq!(ac.commands[0].input_hint, "");
            }
            other => panic!("unexpected variant: {:?}", other),
        }
    }

    #[test]
    fn translates_available_commands_update_with_unstructured_input() {
        let cmd = acp::AvailableCommand::new("rename", "Rename the session")
            .input(Some(acp::AvailableCommandInput::Unstructured(
                acp::UnstructuredCommandInput::new("new session name"),
            )));
        let upd = acp::AvailableCommandsUpdate::new(vec![cmd]);
        let events = translate_session_update(acp::SessionUpdate::AvailableCommandsUpdate(upd));

        assert_eq!(events.len(), 1);
        match events[0].event.as_ref().expect("event") {
            amux::acp_event::Event::AvailableCommands(ac) => {
                assert_eq!(ac.commands[0].input_hint, "new session name");
            }
            other => panic!("unexpected variant: {:?}", other),
        }
    }
}
```

- [ ] **Step 2: Run tests, verify they fail**

Run: `cd daemon && cargo test --lib agent::adapter:: 2>&1 | tail -20`
Expected: compilation error — `no variant named AvailableCommands` on `amux::acp_event::Event`, OR a missing branch panic. Either way: NOT PASSING.

- [ ] **Step 3: Add the match arm in translate_session_update**

Edit `daemon/src/agent/adapter.rs`. Inside `translate_session_update`'s `match update` (around line 203-330), insert this arm **before** the catch-all `_ => { debug!(...); vec![] }`:

```rust
        acp::SessionUpdate::AvailableCommandsUpdate(upd) => {
            let commands = upd
                .available_commands
                .into_iter()
                .map(|c| {
                    let input_hint = match c.input {
                        Some(acp::AvailableCommandInput::Unstructured(u)) => u.hint,
                        _ => String::new(),
                    };
                    amux::AcpAvailableCommand {
                        name: c.name,
                        description: c.description,
                        input_hint,
                    }
                })
                .collect();
            vec![amux::AcpEvent {
                event: Some(amux::acp_event::Event::AvailableCommands(
                    amux::AcpAvailableCommands { commands },
                )),
                model: String::new(),
            }]
        }
```

- [ ] **Step 4: Run tests, verify they pass**

Run: `cd daemon && cargo test --lib agent::adapter:: 2>&1 | tail -20`
Expected: `test result: ok. 2 passed`. No warnings about unused imports.

- [ ] **Step 5: Full build check**

Run: `cd daemon && cargo build 2>&1 | tail -5`
Expected: `Finished` with no errors. Warnings OK.

- [ ] **Step 6: Commit**

```bash
git add daemon/src/agent/adapter.rs
git commit -m "feat(daemon): translate ACP AvailableCommandsUpdate to AcpEvent"
```

---

## Task 3: AMUXCore — SlashCommand model + ViewModel dispatch

**Files:**
- Modify: `ios/Packages/AMUXCore/Sources/AMUXCore/ViewModels/AgentDetailViewModel.swift:1-55` (insert struct + property near top) and inside `handleAcpEvent` (around line 301-416).

- [ ] **Step 1: Add the `SlashCommand` struct and `availableCommands` property**

Edit `ios/Packages/AMUXCore/Sources/AMUXCore/ViewModels/AgentDetailViewModel.swift`.

Add the struct **immediately above** `public final class AgentDetailViewModel {` (near line 5):

```swift
public struct SlashCommand: Identifiable, Equatable, Hashable, Sendable {
    public let name: String
    public let description: String
    public let inputHint: String   // "" = no input required
    public var id: String { name }

    public init(name: String, description: String, inputHint: String) {
        self.name = name
        self.description = description
        self.inputHint = inputHint
    }
}
```

Inside the class, **after** the line `public var events: [AgentEvent] = []` (currently line 7), insert:

```swift
    /// Slash commands announced by the attached agent via
    /// ACP `AvailableCommandsUpdate`. Replaced wholesale on each push.
    /// In-memory only — not persisted to SwiftData.
    public var availableCommands: [SlashCommand] = []
```

- [ ] **Step 2: Add the dispatch case**

In the same file, locate `handleAcpEvent` (around line 295). Inside the `switch acp.event` block, add a new case **before** the existing `case .raw(let raw):` arm (around line 403):

```swift
        case .availableCommands(let upd):
            availableCommands = upd.commands
                .filter { !$0.name.isEmpty }
                .map { SlashCommand(name: $0.name,
                                    description: $0.description,
                                    inputHint: $0.inputHint) }
            // No SwiftData mutation; `dirty` stays false.
```

(Leave `dirty` at its current value — this variant does not touch SwiftData nor grouping, so no save/regroup needed.)

- [ ] **Step 3: Build AMUXCore in isolation**

Run: `cd ios/Packages/AMUXCore && swift build 2>&1 | tail -15`
Expected: `Build complete!` with no errors.

If SwiftPM fails because `AMUXCore` is configured as an Xcode-only package target, skip to Step 4 — Xcode is the authoritative build.

- [ ] **Step 4: Build full iOS app via xcodebuild**

Run: `cd ios && xcodebuild -scheme AMUX -destination 'generic/platform=iOS Simulator' -sdk iphonesimulator build 2>&1 | tail -20`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add ios/Packages/AMUXCore/Sources/AMUXCore/ViewModels/AgentDetailViewModel.swift
git commit -m "feat(ios): ingest ACP AvailableCommands into AgentDetailViewModel"
```

---

## Task 4: AMUXUI — SlashCommandsPopup component

**Files:**
- Create: `ios/Packages/AMUXUI/Sources/AMUXUI/AgentDetail/SlashCommandsPopup.swift`

- [ ] **Step 1: Create the popup view**

Write the full content of `ios/Packages/AMUXUI/Sources/AMUXUI/AgentDetail/SlashCommandsPopup.swift`:

```swift
import SwiftUI
import AMUXCore

/// Inline autocomplete popup for ACP slash commands. Rendered by the
/// composer whenever the user's in-progress text matches `/<prefix>`
/// and at least one known command starts with that prefix.
///
/// Stateless: the parent owns `candidates` and the `onTap` handler that
/// inserts `/<name> ` into the composer.
struct SlashCommandsPopup: View {
    let candidates: [SlashCommand]
    let onTap: (SlashCommand) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(candidates) { cmd in
                Button {
                    onTap(cmd)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("/\(cmd.name)")
                            .font(.system(.body, design: .monospaced).weight(.semibold))
                            .foregroundStyle(.primary)
                        Text(cmd.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if cmd.id != candidates.last?.id {
                    Divider().padding(.leading, 14)
                }
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.separator.opacity(0.5), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
        .frame(maxWidth: 320)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }
}

#Preview {
    SlashCommandsPopup(
        candidates: [
            SlashCommand(name: "clear", description: "Clear conversation history", inputHint: ""),
            SlashCommand(name: "compact", description: "Compact the context window", inputHint: ""),
            SlashCommand(name: "rename", description: "Rename this session", inputHint: "new name"),
        ],
        onTap: { _ in }
    )
    .padding()
}
```

- [ ] **Step 2: Build iOS app to verify component compiles**

Run: `cd ios && xcodebuild -scheme AMUX -destination 'generic/platform=iOS Simulator' -sdk iphonesimulator build 2>&1 | tail -20`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add ios/Packages/AMUXUI/Sources/AMUXUI/AgentDetail/SlashCommandsPopup.swift
git commit -m "feat(ios): add SlashCommandsPopup presentation component"
```

---

## Task 5: AMUXUI — ReplySheet composer wiring

**Files:**
- Modify: `ios/Packages/AMUXUI/Sources/AMUXUI/AgentDetail/AgentDetailView.swift:272-283` (thread `availableCommands`) and `:338-495` (private `ReplySheet` struct).

- [ ] **Step 1: Add a `viewModel` reference into the sheet presentation**

Edit `ios/Packages/AMUXUI/Sources/AMUXUI/AgentDetail/AgentDetailView.swift` around line 271-283. The current code:

```swift
        .sheet(isPresented: $showReplySheet) {
            ReplySheet(text: $promptText,
                       isDisabled: !viewModel.isIdle,
                       isStreaming: viewModel.isStreaming,
                       hasAgent: viewModel.hasAgent,
                       agent: viewModel.agent,
                       onSend: { modelId in
                           let t = promptText; promptText = ""
                           Task { try? await viewModel.sendPrompt(t, modelId: modelId, modelContext: modelContext) }
                       },
                       onCancel: { Task { try? await viewModel.cancelTask() } })
                .presentationDetents([.medium])
        }
```

Replace with (add `availableCommands:` argument):

```swift
        .sheet(isPresented: $showReplySheet) {
            ReplySheet(text: $promptText,
                       isDisabled: !viewModel.isIdle,
                       isStreaming: viewModel.isStreaming,
                       hasAgent: viewModel.hasAgent,
                       agent: viewModel.agent,
                       availableCommands: viewModel.availableCommands,
                       onSend: { modelId in
                           let t = promptText; promptText = ""
                           Task { try? await viewModel.sendPrompt(t, modelId: modelId, modelContext: modelContext) }
                       },
                       onCancel: { Task { try? await viewModel.cancelTask() } })
                .presentationDetents([.medium])
        }
```

- [ ] **Step 2: Add the `availableCommands` parameter to `ReplySheet`**

In the same file around line 338, the current declaration:

```swift
private struct ReplySheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var text: String
    let isDisabled: Bool
    let isStreaming: Bool
    let hasAgent: Bool
    let agent: Agent?
    let onSend: (String?) -> Void
    let onCancel: () -> Void
    @FocusState private var isFocused: Bool
    @State private var showFilePicker = false
    @State private var selectedModelId: String?
    @State private var attachedFiles: [String] = []
```

Replace with (one new property, two new `@State`, rest unchanged):

```swift
private struct ReplySheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var text: String
    let isDisabled: Bool
    let isStreaming: Bool
    let hasAgent: Bool
    let agent: Agent?
    let availableCommands: [SlashCommand]
    let onSend: (String?) -> Void
    let onCancel: () -> Void
    @FocusState private var isFocused: Bool
    @State private var showFilePicker = false
    @State private var selectedModelId: String?
    @State private var attachedFiles: [String] = []
    @State private var slashCandidates: [SlashCommand] = []
    @State private var hasPendingSlashCommand: Bool = false
```

- [ ] **Step 3: Add slash-detection helpers inside `ReplySheet`**

Still in `ReplySheet`, **after** `resolvedModelId` / `canSend` computed properties (around line 352-360), add these helpers:

```swift
    /// If `text` is `/<word>` and nothing else, returns the prefix after `/`.
    /// Returns nil when the text does not match.
    private var slashPrefixInProgress: String? {
        let trimmed = text
        guard let first = trimmed.first, first == "/" else { return nil }
        let rest = trimmed.dropFirst()
        guard rest.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) else {
            return nil
        }
        return String(rest)
    }

    /// True when the composer currently holds `/<knownName>` (optionally
    /// followed by a space + argument). Drives the send-button emphasis.
    private var textMatchesKnownCommand: Bool {
        guard text.hasPrefix("/") else { return false }
        let afterSlash = text.dropFirst()
        // Split on first whitespace, take the head.
        let head = afterSlash.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? String(afterSlash)
        guard !head.isEmpty else { return false }
        return availableCommands.contains(where: { $0.name == head })
    }

    /// Hint to display below the composer once a command with an input
    /// hint has been inserted but the user hasn't typed the argument yet.
    private var activeInputHint: String? {
        guard hasPendingSlashCommand, text.hasPrefix("/") else { return nil }
        // Find the command whose `/name ` prefix text starts with.
        for cmd in availableCommands {
            let prefix = "/\(cmd.name) "
            if text == prefix, !cmd.inputHint.isEmpty {
                return cmd.inputHint
            }
        }
        return nil
    }

    private func recomputeSlashCandidates() {
        if let prefix = slashPrefixInProgress {
            let lower = prefix.lowercased()
            slashCandidates = availableCommands
                .filter { $0.name.lowercased().hasPrefix(lower) }
        } else {
            slashCandidates = []
        }
        hasPendingSlashCommand = textMatchesKnownCommand
    }
```

- [ ] **Step 4: Wire the `onChange(of: text)` + overlay + hint line**

In `ReplySheet.body`, the `else` branch currently starts with the `TextEditor(text: $text)` block at line 385-399. Replace the whole `TextEditor` block and the `// Attached files` section that follows with:

```swift
                ZStack(alignment: .bottom) {
                    TextEditor(text: $text)
                        .focused($isFocused)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                        .overlay(alignment: .topLeading) {
                            if text.isEmpty {
                                Text("Send a message…")
                                    .foregroundStyle(.tertiary)
                                    .padding(.horizontal, 21)
                                    .padding(.top, 20)
                                    .allowsHitTesting(false)
                            }
                        }
                        .onChange(of: text) { _, _ in
                            recomputeSlashCandidates()
                        }
                        .onChange(of: availableCommands) { _, _ in
                            recomputeSlashCandidates()
                        }

                    if !slashCandidates.isEmpty {
                        SlashCommandsPopup(
                            candidates: slashCandidates,
                            onTap: { cmd in
                                text = "/\(cmd.name) "
                                slashCandidates = []
                                hasPendingSlashCommand = true
                            }
                        )
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)
                        .animation(.easeInOut(duration: 0.15), value: slashCandidates)
                    }
                }

                if let hint = activeInputHint {
                    Text(hint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 2)
                }

                // Attached files
                if !attachedFiles.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(attachedFiles, id: \.self) { file in
                                HStack(spacing: 4) {
                                    Image(systemName: "doc").font(.caption)
                                    Text(file.split(separator: "/").last.map(String.init) ?? file)
                                        .font(.caption)
                                        .lineLimit(1)
                                    Button { attachedFiles.removeAll { $0 == file } } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .liquidGlass(in: Capsule(), interactive: false)
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                    .padding(.bottom, 4)
                }
```

(Everything else in `ReplySheet.body` — bottom toolbar, model picker, send button — stays as-is for now; we modify only the send button next.)

- [ ] **Step 5: Emphasize the send button when a known slash command is pending**

Locate the send button in `ReplySheet` (around line 465-479):

```swift
                    Button {
                        onSend(resolvedModelId)
                        dismiss()
                    } label: {
                        Image(systemName: "arrow.up")
                            .font(.body)
                            .fontWeight(.semibold)
                            .foregroundStyle(.primary)
                            .frame(width: 40, height: 40)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .liquidGlass(in: Circle())
                    .disabled(!canSend)
                    .opacity(canSend ? 1 : 0.4)
```

Replace with (adds accent-tint when `hasPendingSlashCommand` and `canSend`):

```swift
                    Button {
                        onSend(resolvedModelId)
                        hasPendingSlashCommand = false
                        dismiss()
                    } label: {
                        Image(systemName: "arrow.up")
                            .font(.body)
                            .fontWeight(.semibold)
                            .foregroundStyle(hasPendingSlashCommand && canSend ? Color.white : Color.primary)
                            .frame(width: 40, height: 40)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .liquidGlass(in: Circle(), tint: hasPendingSlashCommand && canSend ? .accentColor : nil)
                    .disabled(!canSend)
                    .opacity(canSend ? 1 : 0.4)
                    .animation(.easeInOut(duration: 0.15), value: hasPendingSlashCommand)
```

**Note:** `liquidGlass(in:tint:)` may not have a nullable-tint overload. If the modifier takes a non-optional `Color`, split into two branches:

```swift
                    .buttonStyle(.plain)
                    .modifier(SendButtonGlassModifier(emphasized: hasPendingSlashCommand && canSend))
                    .disabled(!canSend)
                    .opacity(canSend ? 1 : 0.4)
                    .animation(.easeInOut(duration: 0.15), value: hasPendingSlashCommand)
```

and add this helper near the bottom of the file (after `ReplySheet`'s closing `}`):

```swift
private struct SendButtonGlassModifier: ViewModifier {
    let emphasized: Bool
    func body(content: Content) -> some View {
        if emphasized {
            content.liquidGlass(in: Circle(), tint: .accentColor)
        } else {
            content.liquidGlass(in: Circle())
        }
    }
}
```

Pick whichever compiles. The behavior is identical.

- [ ] **Step 6: Build iOS app end-to-end**

Run: `cd ios && xcodebuild -scheme AMUX -destination 'generic/platform=iOS Simulator' -sdk iphonesimulator build 2>&1 | tail -25`
Expected: `** BUILD SUCCEEDED **`.

If SourceKit in Xcode complains "No such module 'AMUXCore'" on edited files, ignore it — `xcodebuild` is authoritative.

- [ ] **Step 7: Commit**

```bash
git add ios/Packages/AMUXUI/Sources/AMUXUI/AgentDetail/AgentDetailView.swift
git commit -m "feat(ios): inline slash-command autocomplete in composer"
```

---

## Task 6: Manual smoke test

**Files:** none (runtime verification only)

- [ ] **Step 1: Start daemon locally and attach simulator iOS app**

Run (in one terminal): `cd daemon && RUST_LOG=amuxd=info cargo run -- start`
Run (in Xcode or CLI): build + run the iOS app in the simulator, pair to the daemon.

- [ ] **Step 2: Spawn a Claude Code agent**

From iOS: create a new session (existing flow). Wait until the agent reaches `Idle` / shows the chat surface. In daemon logs you should see `ACP session created` and subsequent `unhandled SessionUpdate variant` entries DISAPPEAR for `available_commands_update` (replaced by the new event).

- [ ] **Step 3: Trigger the composer and type `/`**

On iOS: tap the reply arrow → sheet presents → in the `TextEditor`, type `/`. Expect the `SlashCommandsPopup` to appear anchored above the composer bottom toolbar, showing whatever commands the `claude-agent-acp` wrapper announced (Claude typically announces at least `/clear`, `/compact`, `/cost`, plus any user-level `~/.claude/commands/*.md` files).

If no popup appears:
- Check daemon logs for "unhandled SessionUpdate variant" — if still present, the adapter arm may not have landed. Re-verify Task 2.
- Check iOS console for `availableCommands` — inspect via a `print(viewModel.availableCommands)` in the onChange if needed.
- If the wrapper simply never pushes, popup stays empty — functional degradation (not a bug for this iteration per spec).

- [ ] **Step 4: Exercise prefix filter**

Type `/cl` → only commands beginning with `cl` remain.
Type `/xyz` → popup disappears.
Backspace back to `/` → all commands return.

- [ ] **Step 5: Tap a no-input command**

Tap `/clear`. Expect composer text to become `"/clear "` (with trailing space), popup to dismiss, and send button to become accent-tinted.

Tap send. Agent should respond per its `/clear` semantics (typically resets chat).

- [ ] **Step 6: Tap an input-hint command (if available)**

If a command with non-empty `inputHint` is announced (e.g. the wrapper advertises `/rename <name>` with hint `"new name"`): tap it, expect composer = `"/rename "`, hint line `"new name"` visible below composer in secondary color. Type the argument — hint disappears once text extends beyond the `/rename ` prefix. Send.

- [ ] **Step 7: Session isolation check**

Open session A → confirm its commands. Navigate back, open session B → its popup should show its own list (or empty until B's wrapper pushes). Commands from A must not leak into B.

- [ ] **Step 8: Reconnection check**

Toggle simulator's network off for ~5 s, then back on. Reopen the reply sheet, type `/` → popup should still work (cache persists). After the wrapper re-pushes (usually immediately on reconnect), the list is replaced.

- [ ] **Step 9: Degraded path check**

In daemon, temporarily comment out the new `AvailableCommandsUpdate` match arm (simulating a non-pushing wrapper). Rebuild. On iOS, type `/clear` in composer → no popup, no emphasis. Tap send. Claude Code still handles `/clear` as text (existing behavior preserved). Restore the arm and rebuild.

- [ ] **Step 10: Mark task complete**

No commit for this task — manual verification only. If any check fails, file an issue or re-open the related implementation task.
