# iMessage-style Session Composer Design

**Date:** 2026-04-28
**Status:** Spec — pending implementation plan
**Scope:** iOS — `RuntimeDetailView`

## Goal

Replace the current "three glass capsule" bottom toolbar and modal `ReplySheet` on the session detail screen with an iMessage-style inline composer, and replace the top-right prev/next agent navigation with members + agent-settings entry points.

The result: typing happens inline (no sheet), the right-side button morphs through mic / send / stop based on state, and attachments + model selection live in a single `+` drawer.

## Current State

File: `ios/Packages/AMUXUI/Sources/AMUXUI/AgentDetail/RuntimeDetailView.swift`

- **Top right toolbar (`:159-166`):** `chevron.up` / `chevron.down` for prev/next agent
- **Bottom (`:170-281`):** transcribed voice bubble preview + three glass capsule groups (pin + members | mic | agent-logo + reply/stop)
- **`ReplySheet` (`:366-608`):** modal text editor with slash command popup, attached files chip row, paperclip importer, model picker, send button
- **`RecordButton` (`:676-714`):** circular mic with spinning red ring while recording
- **Voice flow:** record → done → transcribed text shown above toolbar with separate Edit/Send buttons

## Design

### Top toolbar

Replace the prev/next chevrons with two buttons:

In `ToolbarItemGroup(placement: .navigationBarTrailing)`, declared in this code order (leftmost first, rightmost last):

| Code order | Visual position | Button | Tap action |
|---|---|---|---|
| 1st | Closer to title (left of trailing group) | Members (`person.2` + badge count) | `showMembers = true` |
| 2nd | Far trailing edge (right) | Agent logo (`agentLogoName`, 22×22) | `showSettings = true` |

The members badge count uses the existing `memberBadgeCount` derivation. The agent logo button is hidden when `viewModel.hasRuntime == false` (matches current bottom-toolbar behaviour).

`allAgentIds`, `navigationPath`, `currentIndex`, `canGoUp`, `canGoDown`, `goUp()`, `goDown()` are deleted from the view. The two `init` overloads drop the `allAgentIds:` and `navigationPath:` parameters; all callers updated.

### Bottom composer (single row)

```
[ + ]   [ TextField …               [🎤/⏹/➤] ]
```

#### Layout

A new `SessionComposer` subview sits inside the existing `.safeAreaInset(edge: .bottom)`. It contains:

1. (Optional) horizontal scroll of attachment chips above the input row, when attachments are present
2. The composer row: `+` button (left) + input pill (right, fills width)

The input pill is a rounded `Capsule()` with a `liquidGlass` background containing a multi-line `TextField(…, axis: .vertical, lineLimit: 1...6)` and a trailing state-aware action button.

#### Right-side state-aware button

Driven by `(viewModel.isActive, promptText.isEmpty, voiceRecorder.state)`:

| Condition | Icon | Action |
|---|---|---|
| `isActive` (agent running) | `stop.fill` (red) | `cancelTask()` |
| `voiceRecorder.state == .recording` | `mic.fill` (red) | `voiceRecorder.stopRecording()` |
| `promptText` non-empty | `arrow.up` | send (with selected model + attachments) |
| Otherwise (idle, empty) | `mic` | `voiceRecorder.startRecording()` |

The stop branch wins unconditionally over text/voice while the agent is running — sending while running is not allowed today and is preserved.

#### Keyboard behaviour

- **Return key = newline.** Do not bind `.onSubmit` to send. The `axis: .vertical` `TextField` inserts newline by default.
- The send action is button-only.

#### Slash commands

Reuse `SlashCommandsPopup` and the existing `slashPrefixInProgress` / `availableCommands` / `hasPendingSlashCommand` logic from `ReplySheet`. The popup floats above the composer row (outside the pill, between the pill and the previous attachment-chip row if any). Implementation: `.overlay(alignment: .top)` on the composer row with a negative Y offset, OR a `VStack` where the popup sits one row above. Cap visible candidates at 5; remainder scrolls. The send-button glass tint emphasis when a known command is queued (currently `SendButtonGlassModifier`) is preserved on the inline send button.

`recomputeSlashCandidates()` runs on `text` and `availableCommands` changes, exactly as in the current sheet.

### Voice recording

Tap mic (when idle and empty):

1. Input pill content is replaced by `RecordingWaveform` (animated row of 5–7 height-varying `Capsule`s, looping `.repeatForever()` opacity/scale animation) and the label "Recording…"
2. The state-aware right button becomes `mic.fill` (red, stop)
3. Tap stop → `voiceRecorder.stopRecording()` → on `.done`, transcribed text is written into `promptText` and `voiceRecorder.reset()` is called
4. The composer returns to text mode; right button now shows `arrow.up` (text non-empty), keyboard does NOT auto-pop (user opts in)

The current Edit/Send transcription bubble (`:172-221`) is removed. There is no intermediate "review transcription" step — voice → text directly.

### Attachment drawer (`+`)

A new `AttachmentDrawerSheet` presented via `.sheet`, `presentationDetents([.fraction(0.4), .medium])`, dragIndicator visible.

Two sections, vertical stack:

**Attach**

| Cell | Action |
|---|---|
| Files | `fileImporter` (current behaviour) — appends file name to `attachedFiles` |
| Camera | `UIImagePickerController` wrapper (`sourceType: .camera`) — captured image saved to a tmp URL, name appended to `attachedFiles` |
| Photos | `PhotosPicker` (PhotosUI, iOS 17) — selected image(s) saved similarly |

**Model**

A list of `runtime.availableModels` (when `hasRuntime` and non-empty). Tapping selects; the resolved id syncs back to `selectedModelId` in the parent. Current selection shows a checkmark. If no runtime, this section is hidden.

#### Attachment transport — out of scope

`viewModel.sendPrompt` does not currently accept attachments. Within this design we:

- Show attachment chips locally (visual confirmation)
- On send, **silently drop attachments** and display a small inline note `"attachments coming soon"` next to the chip row when any are present

Daemon-side attachment transport is a separate follow-up.

## File Structure

**Modified:**
- `ios/Packages/AMUXUI/Sources/AMUXUI/AgentDetail/RuntimeDetailView.swift` — slim down: top toolbar swap, replace bottom inset with `SessionComposer`, delete `ReplySheet`, `RecordButton`, transcription bubble preview, prev/next nav state, `allAgentIds:`/`navigationPath:` from `init`s
- All call sites of `RuntimeDetailView(...)` — drop the two removed parameters

**New files (same directory):**
- `SessionComposer.swift` — input pill + state-aware button + chip row + waveform overlay
- `AttachmentDrawerSheet.swift` — `+` drawer (file/camera/photos + model picker)
- `RecordingWaveform.swift` — animated waveform view shown inside the pill while recording

`SendButtonGlassModifier` and the slash-command popup wiring move into `SessionComposer.swift`.

**Project config:**
- `ios/project.yml` (and regenerated `Info.plist`) — add `NSCameraUsageDescription` and `NSPhotoLibraryUsageDescription` if not already present

## Out of Scope

- Daemon-side attachment transport (image/file delivery to the agent)
- Voice waveform driven by real audio levels (use a static animated mock for now)
- Refactoring `RuntimeDetailViewModel`'s `sendPrompt` signature
- Pin button (deleted; was a no-op)

## Risks / Open Questions

- **Camera permission denial UX** — if `NSCameraUsageDescription` is missing or user denies, the cell should disable cleanly (system alert is fine; no custom error UI in v1).
- **Multi-line TextField height jitter** — `lineLimit(1...6)` should clamp; verify on device that the pill background animates smoothly when growing.
- **SlashCommandsPopup positioning** — anchored above the pill via `.overlay`; need to verify it doesn't collide with the keyboard accessory when very many candidates exist (cap at, say, 5 visible, scroll the rest).
- **`hasRuntime == false` sessions** — collab-only sessions have no runtime, hence no model picker and no agent-settings button. Top-right shows only the members button in that case. Composer still works (no model selection).
