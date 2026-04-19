# iOS Task Detail + UI Rename + Agent Detail Tab-Bar Hide Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a task detail view pushed from the Tasks tab (status-editable, description, related session link), rename the last two user-facing "Work Item" strings to "Task", and hide the tab bar whenever AgentDetailView is on screen.

**Architecture:** `TasksTab` gains a `NavigationStack` path with string-prefix routing (`"task:<id>"` / `"<agentId>"`) mirroring `SessionsTab`'s pattern exactly. `WorkItemListView` rows become `NavigationLink(value: "task:<id>")`. A new `TaskDetailView` (sibling of `WorkItemListView.swift` under `Collab/`) renders status pills (3-way selector), description, related session, and footer metadata. Status mutation fires a new `TeamclawService.updateWorkItemStatus` RPC that mirrors `archiveWorkItem` byte-for-byte — proto / daemon unchanged because `UpdateWorkItemRequest.status` already exists.

**Tech Stack:** SwiftUI (iOS 26), SwiftData `@Model` + `@Query`, SwiftProtobuf, mqtt-nio via `MQTTService`, `Teamclaw_*` protobuf messages (already generated).

**Source spec:** `docs/superpowers/specs/2026-04-19-ios-task-detail-design.md`

---

## File Structure

**Create:**
- `ios/Packages/AMUXUI/Sources/AMUXUI/Collab/TaskDetailView.swift` — detail view with status pills, description, related-session row, metadata footer.

**Modify:**
- `ios/Packages/AMUXCore/Sources/AMUXCore/TeamclawService.swift` — add `updateWorkItemStatus(workItemId:sessionId:status:)` + private `protoStatus(from:)` helper.
- `ios/Packages/AMUXUI/Sources/AMUXUI/Root/TasksTab.swift` — add `@State navigationPath: [String]`, wrap body in `NavigationStack(path:)`, add `navigationDestination(for: String.self)`.
- `ios/Packages/AMUXUI/Sources/AMUXUI/Collab/WorkItemListView.swift` — wrap `WorkItemRow` in `NavigationLink(value:)`; rename title string + empty-state hint.
- `ios/Packages/AMUXUI/Sources/AMUXUI/Collab/WorkItemSheet.swift` — rename "New Work Item" → "New Task".
- `ios/Packages/AMUXUI/Sources/AMUXUI/AgentDetail/AgentDetailView.swift` — add `.toolbar(.hidden, for: .tabBar)` next to the existing `.toolbar(.hidden, for: .bottomBar)`.

**No tests.** The iOS codebase does not currently carry unit/integration tests for MQTT-publish paths or SwiftUI views. Matching the Phase 1 pattern (Tasks 7–14 of the prior plan): commit per task, manual smoke test at the end.

---

## Task 1: Add `TeamclawService.updateWorkItemStatus`

Adds the RPC method. Mirrors `archiveWorkItem` (file: `TeamclawService.swift:448-464`) structure exactly.

**Files:**
- Modify: `ios/Packages/AMUXCore/Sources/AMUXCore/TeamclawService.swift` — insert new method + helper immediately after `archiveWorkItem` closing brace (around line 464).

- [ ] **Step 1: Add the method**

In `ios/Packages/AMUXCore/Sources/AMUXCore/TeamclawService.swift`, find the existing `archiveWorkItem` method (ends around line 464 with its closing `}`). Insert this block immediately after:

```swift
    /// Updates a work item's status via `UpdateWorkItem` RPC. Mirrors
    /// `archiveWorkItem` — fire-and-forget; authoritative state arrives
    /// via `WorkItemEvent.updated` broadcast and flows through
    /// `syncWorkItemEvent`. The call site typically flips `status` on the
    /// SwiftData model first for optimistic UI; if the RPC fails, the next
    /// broadcast will reinstate the prior value.
    ///
    /// - Parameter status: one of `"open"`, `"in_progress"`, `"done"`.
    ///   Any other value is sent as `.unknown` (which SwiftProtobuf skips,
    ///   producing a no-op update on the daemon side).
    public func updateWorkItemStatus(workItemId: String, sessionId: String, status: String) async {
        guard let mqtt else { return }

        var update = Teamclaw_UpdateWorkItemRequest()
        update.sessionID = sessionId
        update.workItemID = workItemId
        update.status = protoStatus(from: status)

        var rpcReq = Teamclaw_RpcRequest()
        rpcReq.requestID = String(UUID().uuidString.prefix(8)).lowercased()
        rpcReq.senderDeviceID = deviceId
        rpcReq.method = .updateWorkItem(update)

        let topic = "teamclaw/\(teamId)/rpc/\(deviceId)/\(rpcReq.requestID)/req"
        guard let data = try? rpcReq.serializedData() else { return }
        try? await mqtt.publish(topic: topic, payload: data, retain: false)
    }

    /// Maps the SwiftData `WorkItem.status` string domain to the protobuf
    /// `WorkItemStatus` enum. Unknown inputs map to `.unknown` — defensive
    /// against future status values landing in the model before this mapper
    /// is updated.
    private func protoStatus(from status: String) -> Teamclaw_WorkItemStatus {
        switch status {
        case "open": return .open
        case "in_progress": return .inProgress
        case "done": return .done
        default: return .unknown
        }
    }
```

- [ ] **Step 2: Build the package to verify it compiles**

Run:
```bash
cd /Volumes/openbeta/workspace/amux/ios && xcodebuild -project AMUX.xcodeproj -scheme AMUXApp -destination 'generic/platform=iOS' build 2>&1 | tail -20
```
Expected: `** BUILD SUCCEEDED **`. (SourceKit false-positive errors about `AMUXCore`/`UIKit` modules in the editor can be ignored — xcodebuild is authoritative.)

- [ ] **Step 3: Commit**

```bash
cd /Volumes/openbeta/workspace/amux
git add ios/Packages/AMUXCore/Sources/AMUXCore/TeamclawService.swift
git commit -m "$(cat <<'EOF'
feat(ios): add TeamclawService.updateWorkItemStatus RPC

Mirrors archiveWorkItem — fire-and-forget UpdateWorkItem RPC with
only sessionID/workItemID/status set. Adds a protoStatus(from:) helper
to map WorkItem.status strings ("open"/"in_progress"/"done") to
Teamclaw_WorkItemStatus enum cases.

No proto/daemon change: UpdateWorkItemRequest.status already exists.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Create `TaskDetailView`

The detail view. No navigation logic in this task — it just renders + calls the service. Task 3 will push into it.

**Files:**
- Create: `ios/Packages/AMUXUI/Sources/AMUXUI/Collab/TaskDetailView.swift`

- [ ] **Step 1: Create the file**

Create `ios/Packages/AMUXUI/Sources/AMUXUI/Collab/TaskDetailView.swift` with exactly this content:

```swift
import SwiftUI
import SwiftData
import AMUXCore

/// Pushable task detail. Rendered via TasksTab's navigationDestination.
/// Takes the WorkItem directly (SwiftData @Model observability re-renders
/// this view when the daemon broadcast reconciles state).
public struct TaskDetailView: View {
    let item: WorkItem
    let sessionViewModel: SessionListViewModel
    let teamclawService: TeamclawService?
    @Binding var navigationPath: [String]

    @Environment(\.modelContext) private var modelContext

    public init(item: WorkItem,
                sessionViewModel: SessionListViewModel,
                teamclawService: TeamclawService?,
                navigationPath: Binding<[String]>) {
        self.item = item
        self.sessionViewModel = sessionViewModel
        self.teamclawService = teamclawService
        self._navigationPath = navigationPath
    }

    public var body: some View {
        List {
            Section {
                Text(item.displayTitle)
                    .font(.title2.weight(.semibold))
                    .textSelection(.enabled)
            }

            Section("Status") {
                HStack(spacing: 8) {
                    statusPill("Open", value: "open")
                    statusPill("In Progress", value: "in_progress")
                    statusPill("Done", value: "done")
                }
                .padding(.vertical, 4)
            }

            if !item.itemDescription.isEmpty {
                Section("Description") {
                    Text(item.itemDescription)
                        .font(.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if !item.sessionId.isEmpty {
                Section("Related Session") {
                    relatedSessionRow
                }
            }

            Section("Info") {
                if !item.createdBy.isEmpty {
                    LabeledContent("Created by", value: item.createdBy)
                }
                LabeledContent("Created", value: item.createdAt.formatted(date: .abbreviated, time: .shortened))
            }
        }
        .navigationTitle("Task")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Status pill

    private func statusPill(_ label: String, value: String) -> some View {
        let selected = item.status == value
        return Button {
            setStatus(value)
        } label: {
            Text(label)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .foregroundStyle(selected ? Color.white : Color.primary)
                .background(selected ? Color.accentColor : Color.clear)
                .clipShape(Capsule())
                .overlay(
                    Capsule().strokeBorder(selected ? Color.clear : Color.secondary.opacity(0.4), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    private func setStatus(_ newValue: String) {
        guard item.status != newValue else { return }
        // Optimistic — SwiftData @Model re-renders this view immediately.
        item.status = newValue
        try? modelContext.save()
        let id = item.workItemId
        let sessionId = item.sessionId
        Task { await teamclawService?.updateWorkItemStatus(workItemId: id, sessionId: sessionId, status: newValue) }
    }

    // MARK: - Related session row

    @ViewBuilder
    private var relatedSessionRow: some View {
        if let agent = sessionViewModel.agents.first(where: { $0.agentId == item.sessionId }) {
            Button {
                navigationPath.append(agent.agentId)
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(agent.sessionTitle.isEmpty ? agent.agentId : agent.sessionTitle)
                            .font(.body)
                            .foregroundStyle(.primary)
                        Text("Tap to open")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
        } else if let collab = sessionViewModel.collabSessions.first(where: { $0.sessionId == item.sessionId }) {
            Button {
                navigationPath.append("collab:\(collab.sessionId)")
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(collab.title.isEmpty ? collab.sessionId : collab.title)
                            .font(.body)
                            .foregroundStyle(.primary)
                        Text("Tap to open")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
        } else {
            HStack {
                Text("Session not loaded yet")
                    .font(.body)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
    }
}
```

**Notes for the implementer:**
- `sessionViewModel.collabSessions` exists on `SessionListViewModel` (see `SessionListViewModel.swift:36`). The collab fallback is defensive — `WorkItem.sessionId` in practice tends to be an Agent's `agentId`, but a collab match keeps the related-session row useful if the daemon ever populates it with a collab session id.
- `CollabSession.title` / `CollabSession.sessionId` fields are the ones used. If the field name differs (e.g. `displayName`), adjust — do not invent.

- [ ] **Step 2: Build the package to verify it compiles**

Run:
```bash
cd /Volumes/openbeta/workspace/amux/ios && xcodebuild -project AMUX.xcodeproj -scheme AMUXApp -destination 'generic/platform=iOS' build 2>&1 | tail -20
```
Expected: `** BUILD SUCCEEDED **`.

If `CollabSession.title` doesn't exist, read `ios/Packages/AMUXCore/Sources/AMUXCore/Models/CollabSession.swift` and substitute the correct display field (common candidates: `displayName`, `name`). Re-build.

- [ ] **Step 3: Commit**

```bash
cd /Volumes/openbeta/workspace/amux
git add ios/Packages/AMUXUI/Sources/AMUXUI/Collab/TaskDetailView.swift
git commit -m "$(cat <<'EOF'
feat(ios): add TaskDetailView

Pushable task detail rendered from TasksTab's navigationDestination.
Shows title, 3-pill status selector (Open / In Progress / Done),
description (if any), related session link (Agent or CollabSession
match on sessionId), and createdBy/createdAt footer.

Status tap is optimistic: flips WorkItem.status + saves modelContext,
then fires TeamclawService.updateWorkItemStatus; daemon broadcast
reconciles via existing syncWorkItemEvent path.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Wire `TasksTab` navigation + make `WorkItemRow` tappable

Turn TasksTab into a navigating host and make rows push into detail.

**Files:**
- Modify: `ios/Packages/AMUXUI/Sources/AMUXUI/Root/TasksTab.swift`
- Modify: `ios/Packages/AMUXUI/Sources/AMUXUI/Collab/WorkItemListView.swift`

- [ ] **Step 1: Rewrite TasksTab.swift**

Replace the entire contents of `ios/Packages/AMUXUI/Sources/AMUXUI/Root/TasksTab.swift` with:

```swift
import SwiftUI
import SwiftData
import AMUXCore

public struct TasksTab: View {
    let pairing: PairingManager
    let connectionMonitor: ConnectionMonitor
    let teamclawService: TeamclawService?
    let mqtt: MQTTService
    let sessionViewModel: SessionListViewModel

    @Environment(\.modelContext) private var modelContext

    @State private var showSettings = false
    @State private var showCreate = false
    @State private var navigationPath: [String] = []

    public init(mqtt: MQTTService,
                pairing: PairingManager,
                connectionMonitor: ConnectionMonitor,
                teamclawService: TeamclawService?,
                sessionViewModel: SessionListViewModel) {
        self.mqtt = mqtt
        self.pairing = pairing
        self.connectionMonitor = connectionMonitor
        self.teamclawService = teamclawService
        self.sessionViewModel = sessionViewModel
    }

    public var body: some View {
        NavigationStack(path: $navigationPath) {
            WorkItemListView(pairing: pairing,
                             connectionMonitor: connectionMonitor,
                             teamclawService: teamclawService,
                             showCreate: $showCreate)
                .navigationTitle("Tasks")
                .navigationBarTitleDisplayMode(.large)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button { showSettings = true } label: {
                            Image(systemName: "gearshape").font(.title3).foregroundStyle(.primary)
                        }
                        .buttonStyle(.plain)
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button { showCreate = true } label: {
                            Image(systemName: "plus").font(.title3).foregroundStyle(.primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .sheet(isPresented: $showSettings) {
                    SettingsView(pairing: pairing,
                                 connectionMonitor: connectionMonitor,
                                 mqtt: mqtt,
                                 sessionViewModel: sessionViewModel)
                }
                .navigationDestination(for: String.self) { id in
                    if id.hasPrefix("task:") {
                        let workItemId = String(id.dropFirst("task:".count))
                        let descriptor = FetchDescriptor<WorkItem>(
                            predicate: #Predicate { $0.workItemId == workItemId }
                        )
                        if let item = (try? modelContext.fetch(descriptor))?.first {
                            TaskDetailView(item: item,
                                           sessionViewModel: sessionViewModel,
                                           teamclawService: teamclawService,
                                           navigationPath: $navigationPath)
                        } else {
                            Text("Task not found")
                        }
                    } else if id.hasPrefix("collab:") {
                        let sessionId = String(id.dropFirst("collab:".count))
                        let descriptor = FetchDescriptor<CollabSession>(
                            predicate: #Predicate { $0.sessionId == sessionId }
                        )
                        if let session = (try? modelContext.fetch(descriptor))?.first {
                            AgentDetailView(collabSession: session, mqtt: mqtt,
                                            deviceId: pairing.deviceId,
                                            peerId: "ios-\(pairing.authToken.prefix(6))",
                                            teamclawService: teamclawService,
                                            navigationPath: $navigationPath)
                        } else {
                            Text("Collab session not found")
                        }
                    } else if let agent = sessionViewModel.agents.first(where: { $0.agentId == id }) {
                        AgentDetailView(agent: agent, mqtt: mqtt,
                                        deviceId: pairing.deviceId,
                                        peerId: "ios-\(pairing.authToken.prefix(6))",
                                        allAgentIds: sessionViewModel.agents.map(\.agentId),
                                        navigationPath: $navigationPath)
                    } else {
                        Text("Agent not found")
                    }
                }
        }
    }
}
```

Key change notes:
- `@State private var navigationPath: [String] = []` added.
- `NavigationStack` → `NavigationStack(path: $navigationPath)`.
- `navigationDestination(for: String.self)` added with three branches: `"task:<id>"`, `"collab:<id>"`, bare agentId. The last two branches are copied verbatim from `SessionsTab.swift:64-88` so agent + collab pushes from a task's related-session row work identically to the Sessions tab.

- [ ] **Step 2: Wrap rows in NavigationLink in WorkItemListView.swift**

In `ios/Packages/AMUXUI/Sources/AMUXUI/Collab/WorkItemListView.swift`, replace the `ForEach` block at lines 44-54 with:

```swift
                    ForEach(workItems, id: \.workItemId) { item in
                        NavigationLink(value: "task:\(item.workItemId)") {
                            WorkItemRow(item: item)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button {
                                archiveTapped(item)
                            } label: {
                                Label("Archive", systemImage: "archivebox.fill")
                            }
                            .tint(.gray)
                        }
                    }
```

(The whole `ForEach` is shown so there's no ambiguity about indentation. The only structural change: `WorkItemRow(item: item)` is now wrapped in `NavigationLink(value: "task:\(item.workItemId)")`, and `.swipeActions` moves from the row to the link.)

- [ ] **Step 3: Build**

Run:
```bash
cd /Volumes/openbeta/workspace/amux/ios && xcodebuild -project AMUX.xcodeproj -scheme AMUXApp -destination 'generic/platform=iOS' build 2>&1 | tail -20
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
cd /Volumes/openbeta/workspace/amux
git add ios/Packages/AMUXUI/Sources/AMUXUI/Root/TasksTab.swift \
        ios/Packages/AMUXUI/Sources/AMUXUI/Collab/WorkItemListView.swift
git commit -m "$(cat <<'EOF'
feat(ios): wire TasksTab navigation + make WorkItemRow tappable

TasksTab now owns a String-prefixed NavigationStack path:
- "task:<id>"   → TaskDetailView
- "<agentId>"   → AgentDetailView (for agent sessions)
- "collab:<id>" → AgentDetailView (for collab sessions)

The latter two branches mirror SessionsTab exactly so pushing from
a task's related-session row works identically to Sessions.

WorkItemRow is wrapped in NavigationLink(value: "task:<id>"); swipe
to archive is preserved on the link.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: UI rename (Work Item → Task)

Last two user-facing strings. No behavior change.

**Files:**
- Modify: `ios/Packages/AMUXUI/Sources/AMUXUI/Collab/WorkItemListView.swift` — lines 40-41, 59.
- Modify: `ios/Packages/AMUXUI/Sources/AMUXUI/Collab/WorkItemSheet.swift` — line 174.

- [ ] **Step 1: Update WorkItemListView.swift**

Change line 41 of `ios/Packages/AMUXUI/Sources/AMUXUI/Collab/WorkItemListView.swift` from:
```swift
                    description: Text("Tap + to create a work item"))
```
to:
```swift
                    description: Text("Tap + to create a task"))
```

Change line 59 from:
```swift
        .navigationTitle("Work Items")
```
to:
```swift
        .navigationTitle("Tasks")
```

(The outer `TasksTab` already sets `.navigationTitle("Tasks")` — making them consistent keeps the display stable regardless of which one SwiftUI resolves at runtime.)

- [ ] **Step 2: Update WorkItemSheet.swift**

Change line 174 of `ios/Packages/AMUXUI/Sources/AMUXUI/Collab/WorkItemSheet.swift` from:
```swift
            .navigationTitle("New Work Item")
```
to:
```swift
            .navigationTitle("New Task")
```

- [ ] **Step 3: Build**

Run:
```bash
cd /Volumes/openbeta/workspace/amux/ios && xcodebuild -project AMUX.xcodeproj -scheme AMUXApp -destination 'generic/platform=iOS' build 2>&1 | tail -20
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
cd /Volumes/openbeta/workspace/amux
git add ios/Packages/AMUXUI/Sources/AMUXUI/Collab/WorkItemListView.swift \
        ios/Packages/AMUXUI/Sources/AMUXUI/Collab/WorkItemSheet.swift
git commit -m "$(cat <<'EOF'
feat(ios): rename "Work Items" / "New Work Item" to "Tasks" / "New Task"

User-facing strings only. SwiftData model, MQTT topics, protobuf,
and daemon still use WorkItem terminology — full-stack rename
deferred.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Hide bottom tab bar on AgentDetailView

One-line change. Applies to every push of AgentDetailView (Sessions tab and the new Tasks → session path).

**Files:**
- Modify: `ios/Packages/AMUXUI/Sources/AMUXUI/AgentDetail/AgentDetailView.swift` — line 157.

- [ ] **Step 1: Add the modifier**

In `ios/Packages/AMUXUI/Sources/AMUXUI/AgentDetail/AgentDetailView.swift`, line 157 currently reads:
```swift
        .toolbar(.hidden, for: .bottomBar)
```
Change it to:
```swift
        .toolbar(.hidden, for: .bottomBar)
        .toolbar(.hidden, for: .tabBar)
```

- [ ] **Step 2: Build**

Run:
```bash
cd /Volumes/openbeta/workspace/amux/ios && xcodebuild -project AMUX.xcodeproj -scheme AMUXApp -destination 'generic/platform=iOS' build 2>&1 | tail -20
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
cd /Volumes/openbeta/workspace/amux
git add ios/Packages/AMUXUI/Sources/AMUXUI/AgentDetail/AgentDetailView.swift
git commit -m "$(cat <<'EOF'
feat(ios): hide bottom tab bar on AgentDetailView

When AgentDetailView is pushed (from Sessions or Tasks tab), hide
the global TabView's tab bar so the chat surface takes the full
height. Matches the existing .bottomBar hide.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Manual smoke test

Install on a simulator or a paired device and walk through the scenarios below. Don't mark complete until every scenario passes.

- [ ] **Step 1: Build + install for simulator**

```bash
cd /Volumes/openbeta/workspace/amux/ios && xcodebuild -project AMUX.xcodeproj -scheme AMUXApp -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build 2>&1 | tail -20
```
Expected: `** BUILD SUCCEEDED **`.

Run the app in the simulator (Xcode ▶ or `open -a Simulator` + `xcrun simctl launch booted com.amux.app`).

- [ ] **Step 2: Walk through smoke scenarios**

1. Open the Tasks tab. The top title reads **"Tasks"** (not "Work Items").
2. Tap `+`. The create sheet title reads **"New Task"**.
3. With no tasks: empty state reads **"Tap + to create a task"**.
4. Create a task with a description. Tap the row. `TaskDetailView` pushes. It shows title, a 3-pill status selector with "Open" filled, the Description section, and the Info (Created) section. No "Related Session" section (sessionId is empty).
5. Tap "In Progress". Pill selection flips immediately (optimistic). Back out to the list — the blue/orange status dot matches the new state. Push again — status still "In Progress" (daemon reconciled).
6. Tap "Done" then "Open" rapidly. No flicker, no crash. Final state persists after a list round-trip.
7. Create a task that the daemon spawns a session for (existing flow — description triggers session creation). When `sessionId` populates, the related-session row appears. Tap it → `AgentDetailView` pushes within the Tasks tab's stack. The tab bar is hidden while on `AgentDetailView`. Swipe back → tab bar returns.
8. Go to Sessions tab. Push any agent. The tab bar is hidden. Swipe back → tab bar returns.
9. Rotate between Tasks and Sessions while deep in a detail view. Each tab's navigation state is preserved (`TabView` + per-tab `NavigationStack` default behavior).
10. Archive a task via swipe from the list → row animates out. Open the "Archived (N)" row → archived task is listed.

- [ ] **Step 3: If all scenarios pass, mark this task complete.**

If any scenario fails, diagnose and fix before marking complete. Common failure modes:
- Tab bar still visible on AgentDetailView → check both toolbar modifiers are present and in the right `.navigationDestination` branch.
- Related-session row shows "Session not loaded yet" indefinitely → the `sessionId` value from daemon isn't matching any `agent.agentId` nor any `CollabSession.sessionId`. Log `item.sessionId` vs `sessionViewModel.agents.map(\.agentId)` to identify the mismatch.
- Status pill taps don't broadcast → verify `teamclawService` is non-nil and MQTT is connected at tap time.

---

## Self-Review Notes

- **Spec coverage:** All three spec goals (task detail view, UI rename, tab-bar hide) have dedicated tasks. Non-goals (full-stack rename, multi-session, status history, editing title) explicitly excluded.
- **No placeholders:** Every code step has complete code. Expected outputs on every build command.
- **Type consistency:** `updateWorkItemStatus(workItemId:sessionId:status:)` signature identical between Task 1 (definition) and Task 2 (call site). `"task:"` prefix identical between Task 2 (not used), Task 3 (destination) and Task 3 step 2 (NavigationLink value). `navigationPath: [String]` shape consistent throughout and compatible with existing `AgentDetailView(..., navigationPath: Binding<[String]>)` signature.
- **Deviation from spec:** Spec mentioned a typed `TasksPath` enum; the plan uses the string-prefix pattern (`"task:<id>"`) instead. Reason: consistency with `SessionsTab`'s `.navigationDestination(for: String.self)` and direct binding compatibility with the existing `AgentDetailView(..., navigationPath: Binding<[String]>)` API. Functionally identical.
