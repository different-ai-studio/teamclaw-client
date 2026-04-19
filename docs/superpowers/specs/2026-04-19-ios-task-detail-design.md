# iOS Task Detail + UI Rename + Agent Detail Tab-Bar Hide — Design

**Date:** 2026-04-19
**Status:** Approved (brainstorm phase complete)

## Problem

Three related iOS UX gaps block the Tasks tab from feeling finished:

1. **No task detail view.** Tapping a work item row today is a no-op — users can't see the full description, can't change status from the list, and can't jump from a work item to the session the daemon started for it. The list is terminal.
2. **"Work Item" terminology is leaking.** The user-facing model is "Task" (that's the tab name and the brand direction), but the list header still says "Work Items" and the create sheet still says "New Work Item".
3. **Agent detail still shows the global tab bar.** When a user pushes into an `AgentDetailView` (from Sessions tab *or* from the new Tasks → session path), the bottom tab bar remains visible and crowds the chat surface.

## Goals

- Add a `TaskDetailView` pushed from the Tasks tab's `NavigationStack`. Shows title, description, editable status, related session (if any), and footer metadata.
- Rename the two user-facing strings: "Work Items" → "Tasks", "New Work Item" → "New Task".
- Hide the tab bar whenever `AgentDetailView` is on screen.

## Non-Goals (Explicitly Deferred)

- **Full-stack rename.** Not renaming `WorkItem` SwiftData model, `workItemId` fields, `Teamclaw_*WorkItem*` protobuf messages, `teamclaw/*/workitems/*` MQTT topics, or daemon `workitems.toml`. Full-stack rename has cross-platform blast radius (daemon + iOS simultaneously), SwiftData migration cost, and would shadow `Swift.Task`. User accepted UI-only for now.
- **Multi-session tasks.** `WorkItem.sessionId` is a single optional string today; keeping that shape. Related-session row shows 0 or 1 session.
- **Status history / audit log.** Just mutate current status.
- **Editing title/description from detail view.** Read-only except status.

## Architecture

```
TasksTab (NavigationStack, @State navigationPath: [TasksPath])
├── WorkItemListView (tab root)           // unchanged shape, rows become NavigationLink(value: .task(id))
│   └── NavigationLink(value: .task(id))  → push .task(workItemId)
│
├── navigationDestination(for: TasksPath)
│   ├── .task(id)  → TaskDetailView       // NEW
│   │   └── Related Session row
│   │       └── NavigationLink(value: .agent(agentId))  → push .agent(agentId)
│   └── .agent(id) → AgentDetailView      // existing view, reused; hides tab bar
```

`TasksPath` is a typed enum (`.task(String)` / `.agent(String)`) instead of string prefixes — cleaner dispatch, no parse errors.

`TaskDetailView` lives under `ios/Packages/AMUXUI/Sources/AMUXUI/Collab/TaskDetailView.swift` as a sibling to `WorkItemListView.swift` and `WorkItemSheet.swift`.

Status mutation goes through a new `TeamclawService.updateWorkItemStatus(workItemId:sessionId:status:)`, mirroring the existing `archiveWorkItem` RPC pattern exactly. Daemon already accepts `WorkItemStatus` in `UpdateWorkItemRequest` — **no proto change, no daemon change**.

## Components

### 1. `TaskDetailView`

Layout (top-to-bottom `List`-based):

- **Title** (large, `.font(.title2.weight(.semibold))`)
- **Status selector** — 3 pill buttons (Open / In Progress / Done) in a horizontal stack. Selected pill is filled; unselected are liquid-glass outlined. Tapping a pill calls `updateStatus(newStatus)` — optimistic SwiftData write, then fires-and-forgets `TeamclawService.updateWorkItemStatus(...)`. Broadcast from daemon reconciles via existing `syncWorkItemEvent` path.
- **Description** section — multi-line `Text(item.itemDescription)` with `.textSelection(.enabled)`. Preserves newlines. Hidden if empty.
- **Related Session** row — shown only if `item.sessionId != ""` AND a matching `Agent` exists in SessionListViewModel's cache. Row is a `NavigationLink(value: TasksPath.agent(agentId))`. If `sessionId` is set but no agent is found (daemon hasn't reported it yet), show a disabled greyed-out row with caption "Session not loaded yet".
- **Footer metadata** section — `createdBy`, `createdAt` as relative date.

Status pill mapping (UI label → WorkItem.status string):
- Open → `"open"`
- In Progress → `"in_progress"`
- Done → `"done"`

### 2. `TeamclawService.updateWorkItemStatus`

```swift
public func updateWorkItemStatus(workItemId: String, sessionId: String, status: String) async {
    guard let mqtt, let teamId, let deviceId, let peerId else { return }
    var update = Teamclaw_UpdateWorkItemRequest()
    update.workItemID = workItemId
    update.sessionID = sessionId
    update.status = protoStatus(from: status)    // maps "open"→.open, etc.
    var method = Teamclaw_RpcMethod()
    method.method = .updateWorkItem(update)
    var rpcReq = Teamclaw_RpcRequest()
    rpcReq.requestID = UUID().uuidString
    rpcReq.peerID = peerId
    rpcReq.timestamp = Int64(Date().timeIntervalSince1970)
    rpcReq.method = method
    let topic = "teamclaw/\(teamId)/rpc/\(deviceId)/\(rpcReq.requestID)/req"
    let data = try? ProtoMQTTCoder.encode(rpcReq)
    if let data { try? await mqtt.publish(topic: topic, payload: data) }
}
```

Pattern is copied verbatim from `archiveWorkItem`. No response handling — the daemon broadcasts the mutation on the shared workitems topic and `syncWorkItemEvent` reconciles SwiftData, same as archive.

### 3. `TasksTab` navigation wiring

- Change `@State navigationPath: [String]` → `@State navigationPath: [TasksPath]`.
- Add single `.navigationDestination(for: TasksPath.self)` switch:
  - `.task(id)`: fetch `WorkItem` from `modelContext` by `workItemId`, render `TaskDetailView(item:)`.
  - `.agent(id)`: fetch `Agent` from `SessionListViewModel`, render existing `AgentDetailView(...)`.
- `WorkItemListView` rows: wrap existing `WorkItemRow(item:)` in `NavigationLink(value: TasksPath.task(item.workItemId))`.

### 4. Rename (UI strings only)

- `WorkItemListView.swift:59`: `.navigationTitle("Work Items")` → `.navigationTitle("Tasks")`
- `WorkItemSheet.swift:174`: `.navigationTitle("New Work Item")` → `.navigationTitle("New Task")`

Empty-state text "No Tasks" is already correct from Task 7. No other user-facing "Work Item" strings exist in AMUXUI.

### 5. Agent detail tab-bar hide

- `AgentDetailView.swift:157`: add `.toolbar(.hidden, for: .tabBar)` adjacent to the existing `.toolbar(.hidden, for: .bottomBar)`.

This applies whenever AgentDetailView is pushed — from Sessions tab *or* from Tasks → session.

## Data Flow

**Reading:** `TaskDetailView` takes `let item: WorkItem` by value; SwiftData observes the `@Model`, so status changes and daemon-originated updates re-render the detail view automatically.

**Writing status:**
1. User taps pill → `item.status = newStatus; try? modelContext.save()` (optimistic; pill selection updates immediately).
2. `Task { await teamclawService.updateWorkItemStatus(...) }` fires RPC.
3. Daemon broadcasts on workitems topic → iOS `syncWorkItemEvent` merges authoritative state.
4. If the broadcast diverges (e.g. daemon rejected), `@Query` on the list and `@Model` on the detail both update.

This is exactly the archive-tap flow, just for a different field.

## Error Handling

Follows the archive precedent: fire-and-forget RPC, trust broadcast reconcile. If the MQTT publish fails, the optimistic update will drift until the next broadcast corrects it. No user-facing error surface — matches the rest of the Tasks UI.

"Session not loaded yet" state on the related-session row handles the race where `sessionId` is populated but `Agent` hasn't arrived from the daemon yet.

## Testing

Manual smoke test on simulator, consistent with the rest of the iOS work in this repo:

1. Create a task with description → detail view shows description.
2. Tap each status pill → selection updates immediately; verify daemon broadcast arrives (check logs) and status persists on re-open.
3. Create a task that spawns a session (existing flow) → related session row appears; tap it → AgentDetailView pushes *within Tasks tab*; tab bar is hidden.
4. From Sessions tab, push AgentDetailView → tab bar is hidden.
5. Rotate between tabs → Tasks navigation state survives (TabView preserves stacks).
6. Verify "Tasks" and "New Task" titles render correctly.

## Migration Map (files changed)

- **Create:** `ios/Packages/AMUXUI/Sources/AMUXUI/Collab/TaskDetailView.swift`
- **Modify:** `ios/Packages/AMUXCore/Sources/AMUXCore/TeamclawService.swift` — add `updateWorkItemStatus` + private `protoStatus(from:)` helper.
- **Modify:** `ios/Packages/AMUXUI/Sources/AMUXUI/Root/TasksTab.swift` — add `TasksPath` enum, change `navigationPath` type, add `navigationDestination(for: TasksPath.self)`.
- **Modify:** `ios/Packages/AMUXUI/Sources/AMUXUI/Collab/WorkItemListView.swift` — wrap rows in `NavigationLink(value:)`, rename title string.
- **Modify:** `ios/Packages/AMUXUI/Sources/AMUXUI/Collab/WorkItemSheet.swift` — rename title string.
- **Modify:** `ios/Packages/AMUXUI/Sources/AMUXUI/AgentDetail/AgentDetailView.swift` — add `.toolbar(.hidden, for: .tabBar)` at line 157.

No protobuf, no daemon, no XcodeGen regen (no new target files outside existing SPM packages).
