# macOS / iOS Feature Parity — Design

**Status:** Design approved 2026-04-19. Implementation plan to follow.

## Goal

Bring the AMUX macOS client to functional parity with the iOS client, preserving the existing 3-column Mac shell. Delivered as one umbrella spec → one umbrella plan → executed end-to-end in priority order.

## Non-goals

- Redesigning the Mac main window, sidebar sections, or detail-pane architecture.
- Consolidating iOS and Mac shells into a single cross-platform shell.
- Rewriting `AgentDetailViewModel`, `TeamclawService`, or any other ViewModel in `AMUXCore`.
- Adding Mac-specific features that iOS does not have (e.g., AppleScript, menu-bar status item).

## Constraints (locked decisions)

1. **Functional parity, Mac-native UX.** Same capabilities as iOS; shape may differ (desktop idioms over phone idioms).
2. **Preserve the current Mac shell.** 3-column `NavigationSplitView` (sidebar | list | detail), existing sidebar sections (Sessions, Tasks, Workspaces, Members), existing `SessionDetailView` in the detail pane — all stay.
3. **Dedicated windows for membership/collab flows.** Where iOS uses a sheet, Mac uses a secondary `WindowGroup` (Members, Invite, Task editor).
4. **Shared ViewModels only.** ViewModels already live in `AMUXCore`; alignment work extracts duplicated *view-layer* leaves into a new shared UI package.
5. **One big spec → one big plan → ship sequentially.** No sub-project split.

## Priority order (daily-use first)

1. Task Detail view + editor window
2. Permission banner + `UNUserNotification` fallback
3. Members + Invite (dedicated windows)
4. Composer slash-commands popup
5. Unified search
6. Archived tasks disclosure
7. Mac-as-host pairing QR display
8. Connection banner overlay

Everything below elaborates on how each lands. The implementation plan follows this numbering.

## Parity gap inventory

Features iOS has that macOS either lacks or has only a stub for:

| Area | Gap on Mac |
|---|---|
| Task detail | No full detail view; `DetailPlaceholderView.taskPreview` is a stub. No status-change UI, no subtask browsing, no edit flow. |
| Task CRUD | No create/edit sheet equivalent to iOS `WorkItemSheet`. |
| Members | Only `MemberPickerSheet` exists. No `MemberListView`, no invite flow, no remove. |
| Collab invites | No `InviteSheet` — can't generate or share an `amux://` invite URL / QR from Mac. |
| Permission requests | No `PermissionBannerView` inline in the event feed; no `UNUserNotification` when backgrounded. |
| Composer | No `SlashCommandsPopup` autocomplete. |
| Search | No unified cross-session search (per-session search exists). |
| Pairing | No QR display when Mac acts as the host for another client's pairing. |
| Connection UX | No `ConnectionBannerOverlay` for transient offline/reconnect events. |
| Archived tasks | No way to browse archived work items (can archive via context menu, not review). |

## Architecture

### Package structure

Add a new SPM package: **`AMUXSharedUI`**
- Location: `ios/Packages/AMUXSharedUI/` (sibling of `AMUXCore` so both `AMUXUI` and `AMUXMacUI` can reference it via relative path; Mac already depends on `ios/Packages/AMUXCore`).
- Platforms: `iOS(.v26)`, `macOS(.v26)`.
- Dependencies: `AMUXCore`, `swift-markdown` (moved from `AMUXUI`).

**Lives in `AMUXSharedUI`** (platform-agnostic leaf views):
- `MarkdownRenderer` (consolidates both existing copies)
- `StreamingTextView`
- `TodoListView` (consolidates both existing copies)
- `ToolCallView` (consolidates both existing copies)
- `SlashCommandsPopup` body (hosts wire the anchor)
- `PermissionBanner` body (hosts wire actions)
- `AgentStatusPill`
- `ConnectionStatusBadge`
- `ConnectionBanner` body (used by iOS `ConnectionBannerOverlay` and Mac `MainWindowView` overlay)
- `MemberListContent` (moved from `AMUXUI/Members/`)
- `QRCodeView` helper (wraps `CIFilter.qrCodeGenerator`)

**Stays in `AMUXUI`** (iOS shell):
- `RootTabView`, all `*Tab.swift`, `SessionListView`, `AgentDetailView`, `NewSessionSheet`, iOS `PairingView`, `QRScannerView`, iOS sheet flows (`InviteSheet`, `NewCollabSheet`, `MemberInviteSheet`, `WorkItemSheet`, `TaskDetailView`).

**Stays in `AMUXMacUI`** (Mac shell):
- `MainWindowView`, `SidebarView`, `SessionListColumn`, `SessionRow`, `SessionDetailView`, `ComposerView`, Mac `PairingView`, `SettingsScene`, `DaemonStatusFooter`.
- **New Mac-only files:** `TaskDetailView` (Mac variant), `MembersWindow`, `TaskEditorWindow`, `InviteWindow`, `UnifiedSearchResultsView`, `InviteQRSheet` (hosted inside `AccountPreferencesView`).

**Migration rule:** when porting a feature, any leaf view that's platform-agnostic (no iOS-only or Mac-only API, no platform-specific chrome) moves to `AMUXSharedUI` in the same change that adds the Mac caller. Both hosts get rewired to the new module in the same commit — no parallel copies survive.

### Data flow

No new services. Everything routes through existing `AMUXCore` types:
- `TeamclawService` for collab sessions, work items, members.
- `AgentDetailViewModel` per-session for events + permission requests + slash commands.
- `SessionListViewModel`, `MemberListViewModel`.
- `MQTTService` + `SharedConnection` — secondary windows share the one MQTT connection already wired in `AMUXMacApp.swift`.

### Window lifecycle

Secondary Mac windows use `WindowGroup(id:for:)` with `@Environment(\.openWindow)`-based launching.
- `MembersWindow(id: "amux.members")` — singleton.
- `TaskEditorWindow(id: "amux.taskEditor", for: TaskEditorInput.self)` — one per edit target; `TaskEditorInput` is a `Codable` struct with `workItemId: String?` (nil = new task) and `parentTaskId: String?`.
- `InviteWindow(id: "amux.invite", for: InviteIntent.self)` — one per invite flow.
- State uses `SceneStorage` keyed by window id, mirroring the existing `DetailWindowScene` pattern.
- Unsaved-edit guard: closing `TaskEditorWindow` with dirty state surfaces an `.alert` to confirm discard.

### Notifications (permission requests)

- `AMUXMacApp.init` registers one `UNNotificationCategory` with id `AGENT_PERMISSION` and two actions, `GRANT` and `DENY`.
- Handler (attached via a small `NSApplicationDelegateAdaptor`) receives `UNNotificationResponse` → decodes `agentId`, `requestId`, `toolName` from `userInfo` → locates the active `AgentDetailViewModel` for that agent and calls `grantPermission` / `denyPermission`.
- Tapping the notification body (no action) brings the app to the foreground and sets `selectedSessionId` on the main window to the session owning that request.
- First-launch flow requests `UNUserNotificationCenter.requestAuthorization([.alert, .sound])`. If the user denies, the in-app banner still works — no silent failure.

## Feature designs

### 1. Task Detail

- Replace `DetailPlaceholderView.taskPreview` with a full Mac `TaskDetailView`.
- Rendered in the existing detail pane when `selectedSessionId == nil && selectedTaskId != nil` (session takes precedence, matching current `DetailPlaceholderView` ordering).
- Content (mirrors iOS `TaskDetailView`): title, description, status pill, claim info (assignee, claimed-at), linked-session link, subtask list, "Open in session" button, edit button.
- Status changes call `TeamclawService.updateWorkItemStatus` (shipped earlier for iOS).
- Edit button → `openWindow(id: "amux.taskEditor", value: TaskEditorInput(workItemId: task.workItemId, parentTaskId: nil))`.
- Create-task entry point: sidebar `TaskListColumn` header gets a "+" button → opens `TaskEditorWindow` in "new" mode (`workItemId: nil`).

### 2. Permission banner + notifications

- `PermissionBanner` in `AMUXSharedUI`: stateless view taking a `PendingPermission` model (already defined in `AMUXCore`) and grant/deny closures.
- Host in Mac `SessionDetailView` above the event feed: `if let pending = agentVM.pendingPermission { PermissionBanner(...) }`. iOS `AgentDetailView` rewires to the shared view in the same PR.
- A small Mac-only observer (`PermissionNotificationObserver`, lives in `AMUXMacUI`) subscribes to each active `AgentDetailViewModel`'s `pendingPermission` publisher. When a new request arrives *and* `NSApp.isActive == false`, the observer schedules a `UNNotificationRequest` using the registered category. When the request is resolved (granted/denied in-app, or resolved by the daemon), the observer calls `removeDeliveredNotifications(withIdentifiers: [requestId])` and `removePendingNotificationRequests(withIdentifiers: [requestId])`. `AMUXCore` is not modified — all notification logic stays on the Mac side.
- Granting or denying via the notification uses the same `AgentDetailViewModel` APIs as the in-app banner — single source of truth.

### 3. Members + Invite (dedicated windows)

- Lift `MemberListContent` into `AMUXSharedUI` (already exists on iOS, extracted in an earlier commit for embedding).
- Mac `MembersWindow`:
  - Singleton window, opened by a button added to the sidebar `Members` section header and by menu item `Cmd+Shift+M`.
  - Contents: `MemberListContent` with full capability — list members grouped by department, role display, remove (context menu), invite button.
  - Invite button → `openWindow(id: "amux.invite", value: InviteIntent.newMember)`.
- Mac `InviteWindow`:
  - Fields: member display name, role (Owner / Member), regenerate link button.
  - Output: generated `amux://join?broker=…&device=…&token=…` URL + QR (rendered via `QRCodeView` from `AMUXSharedUI`).
  - Actions: "Copy link", "Share via Messages…" (opens a share sheet with `NSSharingService(named: .composeMessage)`).
  - Backing RPC: `TeamclawService` invite command (reuses the path `amuxd invite {name}` uses; unchanged from today).
- Delete `MemberPickerSheet.swift` on Mac. Its single caller in `NewSessionSheet` is rewritten to host a filtered `MemberListContent` inline.

### 4. Composer slash commands

- Lift iOS `SlashCommandsPopup` body into `AMUXSharedUI`. Public API: `SlashCommandsPopup(candidates: [AvailableCommand], selectionIndex: Binding<Int>, onPick: (AvailableCommand) -> Void)`.
- In Mac `ComposerView`:
  - Bind a local `slashCandidates` `@State` derived from `agentVM.availableCommands` and the current text.
  - On `onChange(of: text)`, detect leading `/<prefix>` (respecting word boundaries — same rule as iOS); update candidates.
  - Show as a SwiftUI `.popover(isPresented:)` anchored to the text field's trailing edge (Mac-idiomatic; iOS remains an inline overlay).
  - Arrow-up / arrow-down move `selectionIndex`; `Enter` inserts, `Esc` dismisses.
  - Dismiss on space or when `text` no longer starts with `/`.

### 5. Unified search

- Add `.searchable(text: $searchText)` on the Mac main window, attached to the list column.
- When `searchText` is non-empty, `MainWindowView.list` switches to `UnifiedSearchResultsView` (replaces the current `SessionListColumn` / `TaskListColumn`).
- Results grouped: `Sessions` (matching title / members), `Messages` (matching content, shows session title + preview), `Tasks` (matching title / description).
- Tapping a Session result sets `selectedSessionId`; a Task result sets `selectedTaskId`; a Message result sets `selectedSessionId` of its session (scroll-to-message is out of scope for this pass).
- Query is in-memory over existing `@Query` results — no new backend, matches iOS `SearchTab`.

### 6. Archived tasks disclosure

- Add an "Archived" `DisclosureGroup` at the bottom of `TaskListColumn`.
- Default collapsed. Visibility toggled by a context-menu action on the Tasks function row in the sidebar (`"Show archived" / "Hide archived"`), persisted in `@SceneStorage("amux.mainWindow.archivedVisible")`.
- Inside the disclosure: archived `WorkItem`s, each row with an "Unarchive" context-menu action (flips `archivedAt` back to nil via existing archive RPC).
- Detail pane renders archived tasks with the same `TaskDetailView` as live tasks, with a dimmed header style.

### 7. Mac-as-host pairing QR

- iOS `QRScannerView` exists so iOS can scan an invite. The mirror need on Mac is *displaying* an invite for another client.
- Add "Show invite QR for a new client" button to `AccountPreferencesView` (under Settings).
- Action opens a small `InviteQRSheet` (a standard sheet — not a separate window; this is a transient preferences action, not a long-running flow) that shows: the existing broker host, generated `amux://` URL, QR code (`QRCodeView`), regenerate button, "Copy link", "Close".
- Underlying RPC: same `TeamclawService` invite command used by `InviteWindow` — reuse, don't fork.

### 8. Connection banner overlay

- Lift iOS `ConnectionBannerOverlay` into `AMUXSharedUI` as `ConnectionBanner` (stateless; takes `ConnectionState`, `onReconnect` closure).
- Host in `MainWindowView.body`: `.overlay(alignment: .top) { ConnectionBanner(state: monitor.state, onReconnect: forceReconnect) }`.
- Shows: "Reconnecting…" with spinner during transient drops; "Offline — Retry" button if a reconnect fails; auto-dismisses when `state == .connected`.
- Does not replace `DaemonStatusFooter` — footer is the persistent indicator in the sidebar; banner handles transient events.

## Testing

- Reuse existing `AMUXMacUITests` target.
- New snapshot tests:
  - `TaskDetailView` empty / populated / archived.
  - `PermissionBanner` pending / none.
  - `MembersWindow` empty / populated.
  - `SlashCommandsPopup` filtered candidate list.
  - `ConnectionBanner` reconnecting / offline / connected states.
- Manual QA checklist (included with the plan): open each new feature, exercise golden path + one edge case, verify `UNUserNotification` Grant/Deny works when the app is backgrounded.

## Migration / cleanup (bundled with the relevant feature PR)

- Delete after consolidation:
  - `mac/Packages/AMUXMacUI/Sources/AMUXMacUI/Detail/TodoListView.swift` → use shared.
  - `mac/Packages/AMUXMacUI/Sources/AMUXMacUI/Detail/MarkdownRenderer.swift` → use shared.
  - `mac/Packages/AMUXMacUI/Sources/AMUXMacUI/Detail/ToolCallView.swift` → use shared.
  - `mac/Packages/AMUXMacUI/Sources/AMUXMacUI/Members/MemberPickerSheet.swift` → replaced by shared `MemberListContent`-based picker.
- Update `AMUXMacUI/Package.swift` and `AMUXUI/Package.swift` to depend on `AMUXSharedUI`.
- Update `mac/project.yml` and `ios/project.yml` if they reference the UI packages explicitly.

## Risks

- **Risk:** `AMUXSharedUI` becomes a dumping ground and grows into a third shell. *Mitigation:* leaf views only; any file needing a platform-branch bigger than ~10 lines stays per-platform.
- **Risk:** WindowGroup state plumbing on Mac gets flaky (selection bleeds between windows, `SceneStorage` collisions). *Mitigation:* each secondary window pulls state from shared `@Query` + `TeamclawService` rather than holding its own — `SceneStorage` keys are window-id-prefixed.
- **Risk:** `UNUserNotification` Grant/Deny race — user taps Grant after the daemon already resolved the request. *Mitigation:* `AgentDetailViewModel.grantPermission` is already idempotent; handler does best-effort, no-ops if `requestId` is unknown.

## Ordered work breakdown

The implementation plan will follow this sequence. Each step is a PR-sized, independently-shippable chunk.

1. **Create `AMUXSharedUI` package + migrate duplicated leaves.** Move `MarkdownRenderer`, `TodoListView`, `ToolCallView`, `StreamingTextView`, `AgentStatusPill`, `ConnectionStatusBadge` into the new package. Wire `AMUXUI` and `AMUXMacUI` as dependents. Pure refactor — no feature change.
2. **Task Detail on Mac.** `TaskDetailView` + `TaskEditorWindow` + sidebar "+" action. Wire to `TeamclawService.updateWorkItemStatus`.
3. **Permission banner (shared) + Mac notifications.** Lift `PermissionBanner` to `AMUXSharedUI`, rewire iOS host. Add Mac host in `SessionDetailView`. Register `UNNotificationCategory` in `AMUXMacApp` and wire action handlers.
4. **Members window + Invite window.** Lift `MemberListContent` to `AMUXSharedUI`. Add `MembersWindow` + `InviteWindow`. Delete `MemberPickerSheet`.
5. **Composer slash commands.** Lift `SlashCommandsPopup` to `AMUXSharedUI`. Wire Mac `ComposerView` to show it as `.popover`.
6. **Unified search.** Add `UnifiedSearchResultsView` + `.searchable` binding on main window.
7. **Archived tasks disclosure** in `TaskListColumn`.
8. **Settings pairing QR.** `InviteQRSheet` in `AccountPreferencesView`. `QRCodeView` helper in `AMUXSharedUI`.
9. **Connection banner overlay.** Lift to `AMUXSharedUI` as `ConnectionBanner`; host in Mac `MainWindowView` as top overlay.

Each step keeps `AMUXMacApp` green, updates snapshot tests where relevant, and merges before the next begins.
