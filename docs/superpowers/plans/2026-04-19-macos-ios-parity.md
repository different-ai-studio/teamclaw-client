# macOS / iOS Feature Parity — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring the AMUX macOS client to functional parity with the iOS client, preserving the existing 3-column Mac shell, by adding a shared `AMUXSharedUI` package and landing nine feature PRs in priority order.

**Architecture:** A new SPM package `AMUXSharedUI` (depends on `AMUXCore`, platforms iOS 26 + macOS 26) holds platform-agnostic SwiftUI leaf views consumed by both `AMUXUI` (iOS shell) and `AMUXMacUI` (Mac shell). Each landing is an independent commit that keeps `AMUXMacApp` green. Secondary Mac windows use `WindowGroup(id:for:)` with `@Environment(\.openWindow)`. Mac notification category `AGENT_PERMISSION` is registered at app startup so backgrounded permission requests surface as `UNUserNotification`s with Grant/Deny actions.

**Tech Stack:** Swift 5.10, SwiftUI, SwiftData, Swift Package Manager, XcodeGen, `swift-protobuf` (via generated `AMUXCore`), `swift-markdown`, `UserNotifications`, `CoreImage.CIFilterBuiltins` (for QR). Reference spec: `docs/superpowers/specs/2026-04-19-macos-ios-parity-design.md`.

**Global conventions:**
- Work directly on `main` (user preference — no feature worktrees).
- Every task ends with a single commit using conventional commits (`feat(mac):`, `refactor(ui):`, etc.) following the style of existing commits.
- After each task, build *both* targets: `cd mac && xcodegen && xcodebuild -project AMUXMac.xcodeproj -scheme AMUXMac build` **and** `cd ios && xcodegen && xcodebuild -project AMUX.xcodeproj -scheme AMUX -destination 'platform=iOS Simulator,name=iPhone 16' build`. Both must succeed before committing.
- Run test target after each task: `xcodebuild -project mac/AMUXMac.xcodeproj -scheme AMUXMac -destination 'platform=macOS' test`.

---

## Task 1: Create `AMUXSharedUI` and move duplicated leaf views

**Goal:** Stand up the shared package and consolidate leaf views that currently exist in both `AMUXUI` and `AMUXMacUI` or that only need a small diff.

**Files:**
- Create: `ios/Packages/AMUXSharedUI/Package.swift`
- Create: `ios/Packages/AMUXSharedUI/Sources/AMUXSharedUI/AMUXSharedUI.swift`
- Create: `ios/Packages/AMUXSharedUI/Sources/AMUXSharedUI/MarkdownRenderer.swift`
- Create: `ios/Packages/AMUXSharedUI/Sources/AMUXSharedUI/StreamingTextView.swift`
- Create: `ios/Packages/AMUXSharedUI/Sources/AMUXSharedUI/TodoListView.swift`
- Create: `ios/Packages/AMUXSharedUI/Sources/AMUXSharedUI/ToolCallView.swift`
- Create: `ios/Packages/AMUXSharedUI/Sources/AMUXSharedUI/AgentStatusPill.swift`
- Create: `ios/Packages/AMUXSharedUI/Sources/AMUXSharedUI/ConnectionStatusBadge.swift`
- Delete: `mac/Packages/AMUXMacUI/Sources/AMUXMacUI/Detail/MarkdownRenderer.swift`
- Delete: `mac/Packages/AMUXMacUI/Sources/AMUXMacUI/Detail/TodoListView.swift`
- Delete: `mac/Packages/AMUXMacUI/Sources/AMUXMacUI/Detail/ToolCallView.swift`
- Delete: `mac/Packages/AMUXMacUI/Sources/AMUXMacUI/Detail/AgentStatusPill.swift`
- Delete: `ios/Packages/AMUXUI/Sources/AMUXUI/Shared/MarkdownRenderer.swift`
- Delete: `ios/Packages/AMUXUI/Sources/AMUXUI/Shared/StreamingTextView.swift`
- Delete: `ios/Packages/AMUXUI/Sources/AMUXUI/Shared/ConnectionStatusBadge.swift`
- Delete: `ios/Packages/AMUXUI/Sources/AMUXUI/AgentDetail/TodoListView.swift`
- Delete: `ios/Packages/AMUXUI/Sources/AMUXUI/AgentDetail/ToolCallView.swift`
- Modify: `ios/Packages/AMUXUI/Package.swift`
- Modify: `mac/Packages/AMUXMacUI/Package.swift`
- Modify: `ios/project.yml`
- Modify: `mac/project.yml`

---

- [ ] **Step 1.1: Create the `AMUXSharedUI` package manifest**

Write `ios/Packages/AMUXSharedUI/Package.swift`:

```swift
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AMUXSharedUI",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "AMUXSharedUI", targets: ["AMUXSharedUI"]),
    ],
    dependencies: [
        .package(path: "../AMUXCore"),
        .package(url: "https://github.com/apple/swift-markdown.git", from: "0.7.3"),
    ],
    targets: [
        .target(
            name: "AMUXSharedUI",
            dependencies: [
                "AMUXCore",
                .product(name: "Markdown", package: "swift-markdown"),
            ]
        ),
    ]
)
```

- [ ] **Step 1.2: Create the umbrella file**

Write `ios/Packages/AMUXSharedUI/Sources/AMUXSharedUI/AMUXSharedUI.swift`:

```swift
// AMUXSharedUI — platform-agnostic SwiftUI leaf views shared by
// AMUXUI (iOS shell) and AMUXMacUI (Mac shell). ViewModels live in
// AMUXCore; shell-level composition lives per-platform.
```

- [ ] **Step 1.3: Move `MarkdownRenderer`**

Copy `ios/Packages/AMUXUI/Sources/AMUXUI/Shared/MarkdownRenderer.swift` to `ios/Packages/AMUXSharedUI/Sources/AMUXSharedUI/MarkdownRenderer.swift`. Change the top-level type declaration from `struct MarkdownRenderer` (or whatever visibility it has) to `public struct MarkdownRenderer`, and mark initialisers / public members `public`. Delete both original copies (iOS `Shared/MarkdownRenderer.swift` and Mac `Detail/MarkdownRenderer.swift`).

If the iOS and Mac copies differ in behaviour (expected — the Mac copy is a simpler fallback that drops swift-markdown dependency), take the **iOS version** as canonical. The Mac target gains the `swift-markdown` dependency via `AMUXSharedUI`.

- [ ] **Step 1.4: Move `StreamingTextView`, `TodoListView`, `ToolCallView`, `AgentStatusPill`, `ConnectionStatusBadge`**

Repeat Step 1.3 for each file in the list below. Delete both duplicate copies where both exist; delete the iOS-only copy where the iOS package owns the sole definition.

| File | iOS source | Mac source | Canonical source |
|---|---|---|---|
| `StreamingTextView.swift` | `AMUXUI/Shared/` | (n/a — Mac has none) | iOS |
| `TodoListView.swift` | `AMUXUI/AgentDetail/` | `AMUXMacUI/Detail/` | iOS (has more states) |
| `ToolCallView.swift` | `AMUXUI/AgentDetail/` | `AMUXMacUI/Detail/` | iOS (richer renderers) |
| `AgentStatusPill.swift` | (n/a — iOS embeds inline) | `AMUXMacUI/Detail/` | Mac |
| `ConnectionStatusBadge.swift` | `AMUXUI/Shared/` | (n/a) | iOS |

For each file: bump the top-level type and its members to `public`; the type itself must be `public struct Foo: View { public init(...) ... }`.

- [ ] **Step 1.5: Wire `AMUXUI` to depend on `AMUXSharedUI`**

Edit `ios/Packages/AMUXUI/Package.swift` — replace the `dependencies:` and `targets:` blocks with:

```swift
    dependencies: [
        .package(path: "../AMUXCore"),
        .package(path: "../AMUXSharedUI"),
        .package(url: "https://github.com/apple/swift-markdown.git", from: "0.7.3"),
    ],
    targets: [
        .target(
            name: "AMUXUI",
            dependencies: [
                "AMUXCore",
                "AMUXSharedUI",
                .product(name: "Markdown", package: "swift-markdown"),
            ],
            resources: [.process("Resources")]
        ),
    ]
```

Then at the top of every iOS file that previously used one of the moved types, add `import AMUXSharedUI`.

- [ ] **Step 1.6: Wire `AMUXMacUI` to depend on `AMUXSharedUI`**

Edit `mac/Packages/AMUXMacUI/Package.swift`:

```swift
    dependencies: [
        .package(path: "../../../ios/Packages/AMUXCore"),
        .package(path: "../../../ios/Packages/AMUXSharedUI"),
    ],
    targets: [
        .target(
            name: "AMUXMacUI",
            dependencies: [
                .product(name: "AMUXCore", package: "AMUXCore"),
                .product(name: "AMUXSharedUI", package: "AMUXSharedUI"),
            ],
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "AMUXMacUITests",
            dependencies: ["AMUXMacUI"],
            path: "Tests/AMUXMacUITests"
        ),
    ]
```

Add `import AMUXSharedUI` to every Mac file that referenced a moved type.

- [ ] **Step 1.7: Wire the app-level Xcode projects**

Edit `ios/project.yml` — under `packages:`, add:

```yaml
  AMUXSharedUI:
    path: Packages/AMUXSharedUI
```

Under the `AMUX` target's `dependencies:`, add `- package: AMUXSharedUI`.

Edit `mac/project.yml` — under `packages:`, add:

```yaml
  AMUXSharedUI:
    path: ../ios/Packages/AMUXSharedUI
```

Under the `AMUXMac` target's `dependencies:`, add `- package: AMUXSharedUI`.

- [ ] **Step 1.8: Regenerate both Xcode projects**

Run:
```bash
cd /Volumes/openbeta/workspace/amux/ios && xcodegen
cd /Volumes/openbeta/workspace/amux/mac && xcodegen
```

- [ ] **Step 1.9: Build both targets**

Run:
```bash
cd /Volumes/openbeta/workspace/amux/mac && xcodebuild -project AMUXMac.xcodeproj -scheme AMUXMac build
cd /Volumes/openbeta/workspace/amux/ios && xcodebuild -project AMUX.xcodeproj -scheme AMUX -destination 'platform=iOS Simulator,name=iPhone 16' build
```
Expected: both succeed with no warnings about the moved files.

- [ ] **Step 1.10: Run existing test target**

Run:
```bash
xcodebuild -project /Volumes/openbeta/workspace/amux/mac/AMUXMac.xcodeproj -scheme AMUXMac -destination 'platform=macOS' test
```
Expected: PASS (no behaviour changed).

- [ ] **Step 1.11: Commit**

```bash
cd /Volumes/openbeta/workspace/amux
git add ios/Packages/AMUXSharedUI ios/Packages/AMUXUI/Package.swift mac/Packages/AMUXMacUI/Package.swift ios/project.yml mac/project.yml ios/AMUX.xcodeproj mac/AMUXMac.xcodeproj
git add -u  # picks up deletions
git commit -m "refactor(ui): extract AMUXSharedUI package for platform-agnostic leaves"
```

---

## Task 2: Task Detail on Mac + `TaskEditorWindow`

**Goal:** Replace `DetailPlaceholderView.taskPreview` stub with a full Mac-native `TaskDetailView`. Add a secondary `WindowGroup` for creating/editing tasks. Wire sidebar "+" for task creation.

**Files:**
- Create: `mac/Packages/AMUXMacUI/Sources/AMUXMacUI/Tasks/TaskDetailView.swift`
- Create: `mac/Packages/AMUXMacUI/Sources/AMUXMacUI/Tasks/TaskEditorView.swift`
- Create: `mac/Packages/AMUXMacUI/Sources/AMUXMacUI/Tasks/TaskEditorInput.swift`
- Create: `mac/Packages/AMUXMacUI/Sources/AMUXMacUI/Tasks/TaskEditorWindowScene.swift`
- Modify: `mac/Packages/AMUXMacUI/Sources/AMUXMacUI/Detail/DetailPlaceholderView.swift`
- Modify: `mac/Packages/AMUXMacUI/Sources/AMUXMacUI/Sidebar/TaskListColumn.swift`
- Modify: `mac/AMUXMacApp/AMUXMacApp.swift`
- Create: `mac/Packages/AMUXMacUI/Tests/AMUXMacUITests/TaskDetailViewTests.swift`

---

- [ ] **Step 2.1: Add `TaskEditorInput`**

Write `mac/Packages/AMUXMacUI/Sources/AMUXMacUI/Tasks/TaskEditorInput.swift`:

```swift
import Foundation

/// Payload passed to `TaskEditorWindow` via `openWindow(id:value:)`.
/// `workItemId == nil` means "create new task".
public struct TaskEditorInput: Codable, Hashable, Identifiable {
    public let workItemId: String?
    public let parentTaskId: String?
    public let presetSessionId: String?

    public var id: String {
        workItemId ?? "new:\(parentTaskId ?? "")"
    }

    public init(workItemId: String? = nil,
                parentTaskId: String? = nil,
                presetSessionId: String? = nil) {
        self.workItemId = workItemId
        self.parentTaskId = parentTaskId
        self.presetSessionId = presetSessionId
    }
}
```

- [ ] **Step 2.2: Write failing unit test for status-label helper**

Write `mac/Packages/AMUXMacUI/Tests/AMUXMacUITests/TaskDetailViewTests.swift`:

```swift
import XCTest
import AMUXCore
@testable import AMUXMacUI

final class TaskDetailViewTests: XCTestCase {
    func testStatusDisplayForKnownValues() {
        XCTAssertEqual(TaskDetailView.statusDisplay(for: "open"), "Open")
        XCTAssertEqual(TaskDetailView.statusDisplay(for: "in_progress"), "In Progress")
        XCTAssertEqual(TaskDetailView.statusDisplay(for: "done"), "Done")
    }

    func testStatusDisplayForUnknownValue() {
        XCTAssertEqual(TaskDetailView.statusDisplay(for: "archived"), "archived")
        XCTAssertEqual(TaskDetailView.statusDisplay(for: ""), "Unknown")
    }
}
```

- [ ] **Step 2.3: Run the test — expect failure**

```bash
xcodebuild -project /Volumes/openbeta/workspace/amux/mac/AMUXMac.xcodeproj -scheme AMUXMac -destination 'platform=macOS' test -only-testing AMUXMacUITests/TaskDetailViewTests
```
Expected: compile error — `TaskDetailView` not found.

- [ ] **Step 2.4: Implement `TaskDetailView`**

Write `mac/Packages/AMUXMacUI/Sources/AMUXMacUI/Tasks/TaskDetailView.swift`:

```swift
import SwiftUI
import SwiftData
import AMUXCore

/// Mac-native task detail pane. Mirrors iOS TaskDetailView functionality
/// (status change, description, linked session, creator info) in a
/// mouse-first layout with an Edit button that opens TaskEditorWindow.
struct TaskDetailView: View {
    let item: WorkItem
    let teamclawService: TeamclawService
    let mqtt: MQTTService?
    let deviceId: String
    let peerId: String
    @Binding var selectedSessionId: String?

    @Environment(\.modelContext) private var modelContext
    @Environment(\.openWindow) private var openWindow
    @Query private var members: [Member]
    @Query private var agents: [Agent]
    @Query private var collabSessions: [CollabSession]

    static func statusDisplay(for raw: String) -> String {
        switch raw {
        case "open": return "Open"
        case "in_progress": return "In Progress"
        case "done": return "Done"
        case "": return "Unknown"
        default: return raw
        }
    }

    private var creatorLabel: String {
        guard !item.createdBy.isEmpty else { return "—" }
        return members.first(where: { $0.memberId == item.createdBy })?.displayName ?? "Unknown"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                Divider()
                statusSection
                if !item.itemDescription.isEmpty { descriptionSection }
                if !item.sessionId.isEmpty { linkedSessionSection }
                metadataSection
                Spacer(minLength: 40)
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    openWindow(
                        id: "amux.taskEditor",
                        value: TaskEditorInput(workItemId: item.workItemId)
                    )
                } label: {
                    Label("Edit", systemImage: "pencil")
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "checkmark.circle")
                .foregroundStyle(.secondary)
            Text(item.displayTitle)
                .font(.title2.weight(.semibold))
                .textSelection(.enabled)
            Spacer()
        }
    }

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Status").font(.headline)
            HStack(spacing: 8) {
                statusPill("Open", value: "open")
                statusPill("In Progress", value: "in_progress")
                statusPill("Done", value: "done")
            }
        }
    }

    private var descriptionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Description").font(.headline)
            Text(item.itemDescription)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var metadataSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Info").font(.headline)
            LabeledContent("Created by", value: creatorLabel)
            LabeledContent("Created", value: item.createdAt.formatted(date: .abbreviated, time: .shortened))
            LabeledContent("Status", value: Self.statusDisplay(for: item.status))
        }
    }

    @ViewBuilder
    private var linkedSessionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Related Session").font(.headline)
            if let agent = agents.first(where: { $0.agentId == item.sessionId }) {
                Button {
                    selectedSessionId = agent.agentId
                } label: {
                    HStack {
                        Text(agent.sessionTitle.isEmpty ? agent.agentId : agent.sessionTitle)
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            } else if let collab = collabSessions.first(where: { $0.sessionId == item.sessionId }) {
                Button {
                    selectedSessionId = collab.sessionId
                } label: {
                    HStack {
                        Text(collab.title.isEmpty ? collab.sessionId : collab.title)
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            } else {
                Text("Session not loaded yet").foregroundStyle(.secondary)
            }
        }
    }

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
        item.status = newValue
        try? modelContext.save()
        let id = item.workItemId
        let sid = item.sessionId
        Task { await teamclawService.updateWorkItemStatus(workItemId: id, sessionId: sid, status: newValue) }
    }
}
```

- [ ] **Step 2.5: Run test — expect PASS**

```bash
xcodebuild -project /Volumes/openbeta/workspace/amux/mac/AMUXMac.xcodeproj -scheme AMUXMac -destination 'platform=macOS' test -only-testing AMUXMacUITests/TaskDetailViewTests
```
Expected: PASS.

- [ ] **Step 2.6: Implement `TaskEditorView`**

Write `mac/Packages/AMUXMacUI/Sources/AMUXMacUI/Tasks/TaskEditorView.swift`:

```swift
import SwiftUI
import SwiftData
import AMUXCore

/// Editor sheet hosted by `TaskEditorWindowScene`. Handles both "new task"
/// (input.workItemId == nil) and "edit existing" modes.
struct TaskEditorView: View {
    let input: TaskEditorInput
    let teamclawService: TeamclawService
    let onDone: () -> Void

    @Environment(\.modelContext) private var modelContext
    @Query private var allItems: [WorkItem]

    @State private var title: String = ""
    @State private var descriptionText: String = ""
    @State private var status: String = "open"
    @State private var isBusy = false
    @State private var errorMessage: String?
    @State private var isDirty = false
    @State private var showDiscardAlert = false

    private var isNew: Bool { input.workItemId == nil }

    private var editingItem: WorkItem? {
        guard let id = input.workItemId else { return nil }
        return allItems.first(where: { $0.workItemId == id })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isNew ? "New Task" : "Edit Task").font(.title3.weight(.semibold))
            Form {
                TextField("Title", text: $title)
                    .onChange(of: title) { _, _ in isDirty = true }
                TextField("Description", text: $descriptionText, axis: .vertical)
                    .lineLimit(4...8)
                    .onChange(of: descriptionText) { _, _ in isDirty = true }
                Picker("Status", selection: $status) {
                    Text("Open").tag("open")
                    Text("In Progress").tag("in_progress")
                    Text("Done").tag("done")
                }
                .onChange(of: status) { _, _ in isDirty = true }
            }
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") {
                    if isDirty { showDiscardAlert = true } else { onDone() }
                }
                .keyboardShortcut(.cancelAction)
                Button(isNew ? "Create" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(isBusy || title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 480)
        .onAppear(perform: hydrate)
        .alert("Discard changes?", isPresented: $showDiscardAlert) {
            Button("Discard", role: .destructive) { onDone() }
            Button("Keep Editing", role: .cancel) {}
        }
    }

    private func hydrate() {
        guard let item = editingItem else { return }
        title = item.title
        descriptionText = item.itemDescription
        status = item.status.isEmpty ? "open" : item.status
        isDirty = false
    }

    private func save() {
        let trimmedTitle = title.trimmingCharacters(in: .whitespaces)
        guard !trimmedTitle.isEmpty else { return }
        isBusy = true
        errorMessage = nil

        if let existing = editingItem {
            existing.title = trimmedTitle
            existing.itemDescription = descriptionText
            existing.status = status
            try? modelContext.save()
            let id = existing.workItemId
            let sid = existing.sessionId
            let desiredStatus = status
            Task {
                await teamclawService.updateWorkItemStatus(workItemId: id, sessionId: sid, status: desiredStatus)
                await MainActor.run { isBusy = false; onDone() }
            }
        } else {
            let payload = descriptionText.isEmpty ? trimmedTitle : "\(trimmedTitle)\n\n\(descriptionText)"
            Task {
                let ok = await teamclawService.createWorkItem(description: payload)
                await MainActor.run {
                    isBusy = false
                    if ok { onDone() } else { errorMessage = "Failed to create task. Check daemon connection." }
                }
            }
        }
    }
}
```

- [ ] **Step 2.7: Implement `TaskEditorWindowScene`**

Write `mac/Packages/AMUXMacUI/Sources/AMUXMacUI/Tasks/TaskEditorWindowScene.swift`:

```swift
import SwiftUI
import SwiftData
import AMUXCore

public struct TaskEditorWindowScene: Scene {
    let teamclawService: TeamclawService

    public init(teamclawService: TeamclawService) {
        self.teamclawService = teamclawService
    }

    public var body: some Scene {
        WindowGroup(id: "amux.taskEditor", for: TaskEditorInput.self) { $input in
            if let input {
                TaskEditorScene(input: input, teamclawService: teamclawService)
            }
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 520, height: 400)
    }
}

private struct TaskEditorScene: View {
    let input: TaskEditorInput
    let teamclawService: TeamclawService

    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        TaskEditorView(input: input, teamclawService: teamclawService) {
            dismissWindow(id: "amux.taskEditor")
        }
        .modelContainer(for: [WorkItem.self, Agent.self, CollabSession.self, SessionMessage.self, Member.self, AgentEvent.self, Workspace.self])
    }
}
```

- [ ] **Step 2.8: Wire detail placeholder + main scene**

Replace `mac/Packages/AMUXMacUI/Sources/AMUXMacUI/Detail/DetailPlaceholderView.swift`'s `taskPreview(_:)` branch so the detail pane shows the full `TaskDetailView`:

```swift
            } else if let task = selectedTask {
                TaskDetailView(
                    item: task,
                    teamclawService: teamclawService,
                    mqtt: mqtt,
                    deviceId: deviceId,
                    peerId: peerId,
                    selectedSessionId: $selectedSessionId
                )
```

This requires `DetailPlaceholderView` to accept `@Binding var selectedSessionId: String?` — update its initializer and all callers (`MainWindowView.detail`) accordingly.

Remove the `private func taskPreview(_:)` helper entirely.

- [ ] **Step 2.9: Register the window scene and add a sidebar "+"**

In `mac/AMUXMacApp/AMUXMacApp.swift`, after `DetailWindowScene(...)`, add:

```swift
        TaskEditorWindowScene(teamclawService: detailTeamclaw)
```

In `mac/Packages/AMUXMacUI/Sources/AMUXMacUI/Sidebar/TaskListColumn.swift`, add a toolbar item (or header "+" button) that calls:

```swift
openWindow(id: "amux.taskEditor", value: TaskEditorInput())
```

Accept `@Environment(\.openWindow) private var openWindow` on the view.

- [ ] **Step 2.10: Build and run tests**

```bash
cd /Volumes/openbeta/workspace/amux/mac && xcodegen && xcodebuild -project AMUXMac.xcodeproj -scheme AMUXMac build
xcodebuild -project /Volumes/openbeta/workspace/amux/mac/AMUXMac.xcodeproj -scheme AMUXMac -destination 'platform=macOS' test
```
Expected: both succeed.

- [ ] **Step 2.11: Manual smoke test**

Launch the Mac app. Select the `Tasks` function in the sidebar. Click "+" in the task list header — editor window should open. Type a title, click Create — a new task appears in the list. Select it — detail pane shows title/description/status/info. Click a status pill — it becomes highlighted and persists.

- [ ] **Step 2.12: Commit**

```bash
cd /Volumes/openbeta/workspace/amux
git add mac/Packages/AMUXMacUI/Sources/AMUXMacUI/Tasks mac/Packages/AMUXMacUI/Sources/AMUXMacUI/Detail/DetailPlaceholderView.swift mac/Packages/AMUXMacUI/Sources/AMUXMacUI/Sidebar/TaskListColumn.swift mac/Packages/AMUXMacUI/Sources/AMUXMacUI/Window/MainWindowView.swift mac/AMUXMacApp/AMUXMacApp.swift mac/Packages/AMUXMacUI/Tests/AMUXMacUITests/TaskDetailViewTests.swift
git commit -m "feat(mac): add TaskDetailView, TaskEditorWindow, and sidebar + button"
```

---

## Task 3: Permission banner (shared) + Mac UNUserNotification

**Goal:** Move `PermissionBannerView` into `AMUXSharedUI`; host it in Mac `SessionDetailView` above the event feed. Register `AGENT_PERMISSION` notification category in `AMUXMacApp`. Route Grant/Deny actions back through `AgentDetailViewModel`.

**Files:**
- Move: `ios/Packages/AMUXUI/Sources/AMUXUI/AgentDetail/PermissionBannerView.swift` → `ios/Packages/AMUXSharedUI/Sources/AMUXSharedUI/PermissionBanner.swift`
- Create: `mac/Packages/AMUXMacUI/Sources/AMUXMacUI/Permissions/PermissionNotificationObserver.swift`
- Create: `mac/Packages/AMUXMacUI/Sources/AMUXMacUI/Permissions/PermissionNotificationCenter.swift`
- Modify: `mac/Packages/AMUXMacUI/Sources/AMUXMacUI/Detail/SessionDetailView.swift`
- Modify: `mac/AMUXMacApp/AMUXMacApp.swift`
- Modify: `ios/Packages/AMUXUI/Sources/AMUXUI/AgentDetail/AgentDetailView.swift` (update import)
- Modify: `mac/AMUXMacApp/AMUXMac.entitlements` (add `com.apple.security.app-sandbox` is already present; ensure notifications are usable — no special entitlement needed beyond existing)

---

- [ ] **Step 3.1: Move `PermissionBannerView` to shared**

Copy `ios/Packages/AMUXUI/Sources/AMUXUI/AgentDetail/PermissionBannerView.swift` to `ios/Packages/AMUXSharedUI/Sources/AMUXSharedUI/PermissionBanner.swift`. The type is already `public struct PermissionBannerView`; rename the file but keep the type name identical so no call site changes. Remove any iOS-only API (`.liquidGlass` is a modifier defined in AMUXUI; replace it with a cross-platform equivalent).

Replace the two `.liquidGlass(...)` modifier calls with:

```swift
.background(Color.red.opacity(0.15), in: Capsule())          // Deny button
.background(Color.green.opacity(0.15), in: Capsule())        // Allow button
.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))  // outer
```

Delete the iOS original.

- [ ] **Step 3.2: Implement `PermissionNotificationCenter`**

Write `mac/Packages/AMUXMacUI/Sources/AMUXMacUI/Permissions/PermissionNotificationCenter.swift`:

```swift
import Foundation
import UserNotifications
import AppKit

/// Registers the AGENT_PERMISSION notification category and handles
/// user responses. Holds weak handlers keyed by requestId so that when
/// the user taps Grant/Deny on a notification, we call the right
/// ViewModel. A singleton because `UNUserNotificationCenter.delegate`
/// is process-wide.
@MainActor
public final class PermissionNotificationCenter: NSObject, UNUserNotificationCenterDelegate {
    public static let shared = PermissionNotificationCenter()

    public struct Handler {
        public let grant: () -> Void
        public let deny: () -> Void
        public let sessionId: String
    }

    public static let categoryId = "AGENT_PERMISSION"
    public static let grantAction = "GRANT"
    public static let denyAction = "DENY"

    private var handlers: [String: Handler] = [:]
    private var pendingFocusSessionId: String?

    public override init() {
        super.init()
    }

    public func bootstrap() async {
        let center = UNUserNotificationCenter.current()
        center.delegate = self

        let grant = UNNotificationAction(identifier: Self.grantAction, title: "Grant", options: [.authenticationRequired])
        let deny  = UNNotificationAction(identifier: Self.denyAction,  title: "Deny",  options: [.destructive])
        let category = UNNotificationCategory(identifier: Self.categoryId,
                                              actions: [grant, deny],
                                              intentIdentifiers: [],
                                              options: [])
        center.setNotificationCategories([category])

        _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }

    public func register(requestId: String, handler: Handler) {
        handlers[requestId] = handler
    }

    public func unregister(requestId: String) {
        handlers.removeValue(forKey: requestId)
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [requestId])
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [requestId])
    }

    public var onFocusSession: ((String) -> Void)?

    // MARK: - UNUserNotificationCenterDelegate

    public func userNotificationCenter(_ center: UNUserNotificationCenter,
                                       willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        // Even when the app is active we show the banner — the in-app
        // banner is the canonical UI, but a system banner is a nice hint.
        [.banner, .sound]
    }

    public func userNotificationCenter(_ center: UNUserNotificationCenter,
                                       didReceive response: UNNotificationResponse) async {
        let requestId = response.notification.request.identifier
        guard let handler = handlers[requestId] else { return }
        switch response.actionIdentifier {
        case Self.grantAction:
            handler.grant()
        case Self.denyAction:
            handler.deny()
        case UNNotificationDefaultActionIdentifier:
            NSApp.activate(ignoringOtherApps: true)
            onFocusSession?(handler.sessionId)
        default:
            break
        }
        unregister(requestId: requestId)
    }
}
```

- [ ] **Step 3.3: Implement `PermissionNotificationObserver`**

The permission banner is rendered per-event inside the feed (iOS `EventFeedView.swift:44`, Mac `AgentEventRow.permissionBlock`). There is no `pendingPermission` field on `AgentDetailViewModel`; pending requests are inferred from `vm.events` — a permission request is "pending" when `event.eventType == "permission_request" && event.isComplete != true`.

Write `mac/Packages/AMUXMacUI/Sources/AMUXMacUI/Permissions/PermissionNotificationObserver.swift`:

```swift
import SwiftUI
import UserNotifications
import AppKit
import AMUXCore

/// Watches AgentDetailViewModel.events for unresolved permission_request
/// entries. When the app is inactive and a new one arrives, fires a
/// banner with Grant/Deny actions. When the request resolves (by any
/// path — in-app banner or daemon timeout), withdraws the banner.
@MainActor
struct PermissionNotificationObserver: ViewModifier {
    let agentVM: AgentDetailViewModel
    let sessionId: String

    @State private var tracked: Set<String> = []

    func body(content: Content) -> some View {
        content
            .onChange(of: pendingSignature) { _, _ in reconcile() }
    }

    /// A string derived from the current set of pending permission_request
    /// events; changes whenever a new request appears or one is resolved.
    private var pendingSignature: String {
        agentVM.events
            .filter { $0.eventType == "permission_request" && $0.isComplete != true }
            .compactMap { $0.toolId }
            .sorted()
            .joined(separator: ",")
    }

    private func reconcile() {
        let pending = agentVM.events.filter {
            $0.eventType == "permission_request" && $0.isComplete != true
        }
        let pendingIds = Set(pending.compactMap { $0.toolId })

        // Withdraw notifications for requests that are no longer pending.
        for resolved in tracked.subtracting(pendingIds) {
            PermissionNotificationCenter.shared.unregister(requestId: resolved)
        }

        // Schedule notifications for newly pending requests, but only if
        // the app is inactive — if the user is looking at the app, the
        // inline banner in the feed is enough.
        for event in pending where !tracked.contains(event.toolId ?? "") {
            guard let requestId = event.toolId, !requestId.isEmpty else { continue }
            tracked.insert(requestId)
            guard !NSApp.isActive else { continue }

            PermissionNotificationCenter.shared.register(
                requestId: requestId,
                handler: .init(
                    grant: { Task { try? await agentVM.grantPermission(requestId: requestId) } },
                    deny:  { Task { try? await agentVM.denyPermission(requestId: requestId) } },
                    sessionId: sessionId
                )
            )

            let content = UNMutableNotificationContent()
            content.title = "Permission Request"
            content.body = "\(event.toolName ?? "tool"): \(event.text ?? "")"
            content.categoryIdentifier = PermissionNotificationCenter.categoryId
            content.userInfo = [
                "requestId": requestId,
                "sessionId": sessionId,
                "toolName": event.toolName ?? "",
            ]
            let request = UNNotificationRequest(identifier: requestId, content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request) { _ in }
        }

        tracked = pendingIds
    }
}

extension View {
    func observesPermissionNotifications(agentVM: AgentDetailViewModel, sessionId: String) -> some View {
        modifier(PermissionNotificationObserver(agentVM: agentVM, sessionId: sessionId))
    }
}
```

- [ ] **Step 3.4: Unify the inline banner and wire the observer**

The iOS event-feed (`EventFeedView.swift:43-54`) and the Mac event-row (`AgentEventRow.permissionBlock`, ~line 135) each render their own UI for a `permission_request` event. Replace both with the shared `PermissionBannerView`.

**iOS:** `ios/Packages/AMUXUI/Sources/AMUXUI/AgentDetail/EventFeedView.swift` already calls `PermissionBannerView(...)` — just add `import AMUXSharedUI` at the top so it resolves to the shared type.

**Mac:** `mac/Packages/AMUXMacUI/Sources/AMUXMacUI/Detail/AgentEventRow.swift`. Add `import AMUXSharedUI`. Replace the `permissionBlock` body with:

```swift
    private var permissionBlock: some View {
        PermissionBannerView(
            toolName: event.toolName ?? "",
            description: event.text ?? "",
            requestId: event.toolId ?? "",
            isResolved: event.isComplete == true,
            wasGranted: event.success,
            onGrant: event.isComplete == true ? nil : onGrant,
            onDeny: event.isComplete == true ? nil : onDeny
        )
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }
```

**Wire the observer on Mac:** In `mac/Packages/AMUXMacUI/Sources/AMUXMacUI/Detail/SessionDetailView.swift`, attach `.observesPermissionNotifications(agentVM: vm, sessionId: session.sessionId)` to the `ScrollView` (or the outer `VStack`) inside `body` when `agentVM` is non-nil. Since `agentVM` is optional in the current Mac view, thread the modifier through the `agentEventFeed(vm:)` helper:

```swift
    @ViewBuilder
    private func agentEventFeed(vm: AgentDetailViewModel) -> some View {
        // ... existing filtered/grouped event rendering ...
    }
```

and apply the modifier at the call site:

```swift
                    if let vm = agentVM, primaryAgent != nil {
                        agentEventFeed(vm: vm)
                            .observesPermissionNotifications(agentVM: vm, sessionId: session.sessionId)
                    } else {
                        collabMessageFeed
                    }
```

- [ ] **Step 3.5: Bootstrap notifications in `AMUXMacApp`**

Modify `mac/AMUXMacApp/AMUXMacApp.swift`. After the existing `@State` declarations, add:

```swift
    @State private var notificationsReady = false
```

Inside the `WindowGroup`'s `RootView(...)` chain, add:

```swift
        .task {
            guard !notificationsReady else { return }
            await PermissionNotificationCenter.shared.bootstrap()
            PermissionNotificationCenter.shared.onFocusSession = { sid in
                // Activating the window is enough for v1; selecting the
                // session in the current scene happens via SceneStorage
                // binding in MainWindowView.
                NSApp.activate(ignoringOtherApps: true)
                _ = sid
            }
            notificationsReady = true
        }
```

Requires `import AMUXMacUI` (already present).

- [ ] **Step 3.6: iOS rewire**

Update `ios/Packages/AMUXUI/Sources/AMUXUI/AgentDetail/AgentDetailView.swift`: add `import AMUXSharedUI` at top, confirm all `PermissionBannerView(...)` call sites still compile (no change to the struct's init signature).

- [ ] **Step 3.7: Build both targets**

```bash
cd /Volumes/openbeta/workspace/amux/mac && xcodegen && xcodebuild -project AMUXMac.xcodeproj -scheme AMUXMac build
cd /Volumes/openbeta/workspace/amux/ios && xcodegen && xcodebuild -project AMUX.xcodeproj -scheme AMUX -destination 'platform=iOS Simulator,name=iPhone 16' build
```
Expected: both succeed.

- [ ] **Step 3.8: Manual test**

With the daemon running a Claude session that requests tool permission: (1) Mac app foreground — inline banner shows; Grant/Deny works. (2) Mac app backgrounded (press `Cmd+H`) — system notification appears; click Grant → the request resolves and the banner disappears on refocus.

- [ ] **Step 3.9: Commit**

```bash
cd /Volumes/openbeta/workspace/amux
git add ios/Packages/AMUXSharedUI/Sources/AMUXSharedUI/PermissionBanner.swift mac/Packages/AMUXMacUI/Sources/AMUXMacUI/Permissions mac/Packages/AMUXMacUI/Sources/AMUXMacUI/Detail/SessionDetailView.swift mac/AMUXMacApp/AMUXMacApp.swift ios/Packages/AMUXUI/Sources/AMUXUI/AgentDetail/AgentDetailView.swift
git add -u
git commit -m "feat(mac): inline PermissionBanner + UNUserNotification fallback"
```

---

## Task 4: Members window + Invite window

**Goal:** Move `MemberListContent` into `AMUXSharedUI`. Add Mac `MembersWindow` and `InviteWindow`. Replace `MemberPickerSheet` with a filtered `MemberListContent`.

**Files:**
- Move: `ios/Packages/AMUXUI/Sources/AMUXUI/Members/MemberListContent.swift` → `ios/Packages/AMUXSharedUI/Sources/AMUXSharedUI/MemberListContent.swift`
- Create: `mac/Packages/AMUXMacUI/Sources/AMUXMacUI/Members/MembersWindowScene.swift`
- Create: `mac/Packages/AMUXMacUI/Sources/AMUXMacUI/Members/InviteWindowScene.swift`
- Create: `mac/Packages/AMUXMacUI/Sources/AMUXMacUI/Members/InviteIntent.swift`
- Modify: `mac/Packages/AMUXMacUI/Sources/AMUXMacUI/Sidebar/SidebarView.swift` (header button to open Members window)
- Modify: `mac/Packages/AMUXMacUI/Sources/AMUXMacUI/SessionList/NewSessionSheet.swift` (replace `MemberPickerSheet`)
- Delete: `mac/Packages/AMUXMacUI/Sources/AMUXMacUI/Members/MemberPickerSheet.swift`
- Modify: `mac/AMUXMacApp/AMUXMacApp.swift` (register both new scenes)

---

- [ ] **Step 4.1: Move `MemberListContent` to shared**

Copy `ios/Packages/AMUXUI/Sources/AMUXUI/Members/MemberListContent.swift` to `ios/Packages/AMUXSharedUI/Sources/AMUXSharedUI/MemberListContent.swift`. If it uses iOS-only modifiers (e.g. `.swipeActions`, `.refreshable` is cross-platform), wrap them in `#if os(iOS)`. Mark the struct and its init `public` if not already.

Delete the iOS original. Add `import AMUXSharedUI` to every iOS file that previously imported the type.

- [ ] **Step 4.2: Add `InviteIntent`**

Write `mac/Packages/AMUXMacUI/Sources/AMUXMacUI/Members/InviteIntent.swift`:

```swift
import Foundation

public enum InviteIntent: Codable, Hashable {
    case newMember(role: String)
    case rotateExisting(memberId: String)
}
```

- [ ] **Step 4.3: Implement `MembersWindowScene`**

Write `mac/Packages/AMUXMacUI/Sources/AMUXMacUI/Members/MembersWindowScene.swift`:

```swift
import SwiftUI
import SwiftData
import AMUXCore
import AMUXSharedUI

public struct MembersWindowScene: Scene {
    let pairing: PairingManager

    public init(pairing: PairingManager) {
        self.pairing = pairing
    }

    public var body: some Scene {
        Window("Members", id: "amux.members") {
            MembersWindowView(pairing: pairing)
                .frame(minWidth: 480, minHeight: 540)
                .modelContainer(for: [Member.self, CollabSession.self])
        }
        .keyboardShortcut("m", modifiers: [.command, .shift])
    }
}

private struct MembersWindowView: View {
    let pairing: PairingManager
    @Environment(\.openWindow) private var openWindow
    @Environment(SharedConnection.self) private var shared

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Team Members").font(.title3.weight(.semibold))
                Spacer()
                Button {
                    openWindow(id: "amux.invite", value: InviteIntent.newMember(role: "member"))
                } label: {
                    Label("Invite", systemImage: "person.badge.plus")
                }
            }
            .padding(16)
            Divider()
            MemberListContent(
                mqtt: shared.mqtt,
                deviceId: pairing.deviceId,
                peerId: shared.peerId,
                onInviteTapped: {
                    openWindow(id: "amux.invite", value: InviteIntent.newMember(role: "member"))
                }
            )
        }
    }
}
```

If `MemberListContent` does not already take an `onInviteTapped` closure, either add it as an optional parameter in the shared move (Step 4.1) or inline the list here without that hook.

- [ ] **Step 4.4: Implement `InviteWindowScene`**

Write `mac/Packages/AMUXMacUI/Sources/AMUXMacUI/Members/InviteWindowScene.swift`:

```swift
import SwiftUI
import AMUXCore
import AMUXSharedUI

public struct InviteWindowScene: Scene {
    let pairing: PairingManager
    let teamclawService: TeamclawService

    public init(pairing: PairingManager, teamclawService: TeamclawService) {
        self.pairing = pairing
        self.teamclawService = teamclawService
    }

    public var body: some Scene {
        WindowGroup(id: "amux.invite", for: InviteIntent.self) { $intent in
            if let intent {
                InviteWindowView(intent: intent, pairing: pairing, teamclawService: teamclawService)
                    .frame(minWidth: 420, minHeight: 520)
            }
        }
        .windowResizability(.contentSize)
    }
}

private struct InviteWindowView: View {
    let intent: InviteIntent
    let pairing: PairingManager
    let teamclawService: TeamclawService

    @State private var displayName: String = ""
    @State private var inviteURL: String?
    @State private var isGenerating = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Invite a new member").font(.title3.weight(.semibold))

            TextField("Display name (e.g. Alex)", text: $displayName)
                .textFieldStyle(.roundedBorder)

            if let inviteURL {
                VStack(alignment: .center, spacing: 12) {
                    QRCodeView(content: inviteURL)
                        .frame(width: 220, height: 220)
                    Text(inviteURL).font(.caption.monospaced())
                        .textSelection(.enabled)
                    HStack {
                        Button("Copy link") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(inviteURL, forType: .string)
                        }
                        Button("Share via Messages…") {
                            shareViaMessages(text: inviteURL)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }

            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button(isGenerating ? "Generating…" : (inviteURL == nil ? "Generate Invite" : "Regenerate")) {
                    generate()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(isGenerating || displayName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
    }

    private func generate() {
        let trimmed = displayName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        isGenerating = true
        errorMessage = nil
        Task {
            let result = await teamclawService.createInvite(displayName: trimmed)
            await MainActor.run {
                isGenerating = false
                if let url = result { inviteURL = url } else { errorMessage = "Invite failed — check daemon connection." }
            }
        }
    }

    private func shareViaMessages(text: String) {
        let service = NSSharingService(named: .composeMessage)
        service?.perform(withItems: [text])
    }
}
```

If `TeamclawService.createInvite` does not exist yet, this is scoped under Task 4 — add it in the same PR. The daemon already supports `amuxd invite {name}` at the CLI; the RPC path is a small addition. Inspect `TeamclawService.swift` around `createWorkItem` (line ~413) and mirror the shape: build a new `Teamclaw_CreateInviteRequest` proto, publish, and return the resulting `amux://` URL from the response. If the proto message does not exist, add it to `proto/amux.proto` and regenerate (`./scripts/proto-gen-swift.sh` for Swift; Rust is automatic). **If extending the proto is out of scope for this task, alternately:** call out to the existing `amuxd invite` via a subprocess on the Mac (less preferred — breaks MQTT-only assumption). The preferred path is proto extension.

- [ ] **Step 4.5: Add `QRCodeView` helper in `AMUXSharedUI`**

Write `ios/Packages/AMUXSharedUI/Sources/AMUXSharedUI/QRCodeView.swift`:

```swift
import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins

public struct QRCodeView: View {
    let content: String

    public init(content: String) { self.content = content }

    public var body: some View {
        if let image = Self.generate(content: content) {
            #if os(macOS)
            Image(nsImage: image)
                .interpolation(.none)
                .resizable()
                .aspectRatio(1, contentMode: .fit)
            #else
            Image(uiImage: image)
                .interpolation(.none)
                .resizable()
                .aspectRatio(1, contentMode: .fit)
            #endif
        } else {
            Color.gray.opacity(0.2)
        }
    }

    #if os(macOS)
    private static func generate(content: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(content.utf8)
        guard let ci = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)) else { return nil }
        let rep = NSCIImageRep(ciImage: ci)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
    #else
    private static func generate(content: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(content.utf8)
        guard let ci = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)) else { return nil }
        let context = CIContext()
        guard let cg = context.createCGImage(ci, from: ci.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
    #endif
}
```

- [ ] **Step 4.6: Sidebar button for Members**

Modify `mac/Packages/AMUXMacUI/Sources/AMUXMacUI/Sidebar/SidebarView.swift`. Replace the `Section("Members")` header with:

```swift
            Section {
                // ... existing ForEach(MemberGrouping.grouped(members)) unchanged ...
            } header: {
                HStack {
                    Text("Members")
                    Spacer()
                    Button {
                        openWindow(id: "amux.members")
                    } label: {
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Open members window")
                }
            }
```

Add `@Environment(\.openWindow) private var openWindow` at the top of `SidebarView`.

- [ ] **Step 4.7: Register both scenes in `AMUXMacApp`**

Modify `mac/AMUXMacApp/AMUXMacApp.swift`. After `TaskEditorWindowScene(...)`, add:

```swift
        MembersWindowScene(pairing: pairing)
        InviteWindowScene(pairing: pairing, teamclawService: detailTeamclaw)
```

- [ ] **Step 4.8: Replace `MemberPickerSheet`**

Find the one caller: `mac/Packages/AMUXMacUI/Sources/AMUXMacUI/SessionList/NewSessionSheet.swift`. It uses `MemberPickerSheet` to select collab participants. Replace with `MemberListContent(... , selectionMode: .multi, selection: $selectedMembers, showInviteButton: false)` (or equivalent — if `MemberListContent` lacks a multi-select mode, add one: `public init(..., selection: Binding<Set<String>>? = nil)`).

Delete `mac/Packages/AMUXMacUI/Sources/AMUXMacUI/Members/MemberPickerSheet.swift`.

- [ ] **Step 4.9: Build both targets**

```bash
cd /Volumes/openbeta/workspace/amux/mac && xcodegen && xcodebuild -project AMUXMac.xcodeproj -scheme AMUXMac build
cd /Volumes/openbeta/workspace/amux/ios && xcodegen && xcodebuild -project AMUX.xcodeproj -scheme AMUX -destination 'platform=iOS Simulator,name=iPhone 16' build
```
Expected: both succeed.

- [ ] **Step 4.10: Manual test**

Launch Mac app. Click the arrow next to "Members" in the sidebar → Members window opens. Click "Invite" in the Members window → Invite window opens. Type a name, click Generate → QR + URL appear. Click "Copy link" — paste elsewhere, confirm the `amux://join?...` URL is valid. Create a new session via the `+` button in the session list column → member-picker content inlines correctly.

- [ ] **Step 4.11: Commit**

```bash
cd /Volumes/openbeta/workspace/amux
git add ios/Packages/AMUXSharedUI/Sources/AMUXSharedUI mac/Packages/AMUXMacUI/Sources/AMUXMacUI/Members mac/Packages/AMUXMacUI/Sources/AMUXMacUI/Sidebar/SidebarView.swift mac/Packages/AMUXMacUI/Sources/AMUXMacUI/SessionList/NewSessionSheet.swift mac/AMUXMacApp/AMUXMacApp.swift
git add -u
git commit -m "feat(mac): MembersWindow + InviteWindow; drop MemberPickerSheet"
```

---

## Task 5: Composer slash-commands popup

**Goal:** Lift `SlashCommandsPopup` into `AMUXSharedUI`. Show it as a `.popover` anchored to the Mac `ComposerView` text field when text starts with `/` and `agentVM.availableCommands` has matches.

**Files:**
- Move: `ios/Packages/AMUXUI/Sources/AMUXUI/AgentDetail/SlashCommandsPopup.swift` → `ios/Packages/AMUXSharedUI/Sources/AMUXSharedUI/SlashCommandsPopup.swift`
- Modify: `mac/Packages/AMUXMacUI/Sources/AMUXMacUI/Composer/ComposerView.swift`
- Modify: `ios/Packages/AMUXUI/Sources/AMUXUI/AgentDetail/AgentDetailView.swift` (import update)

---

- [ ] **Step 5.1: Move `SlashCommandsPopup` to shared**

Copy the iOS file into `AMUXSharedUI`, marking the type `public struct SlashCommandsPopup`. The current iOS struct (see `ios/Packages/AMUXUI/Sources/AMUXUI/AgentDetail/SlashCommandsPopup.swift`) uses only cross-platform APIs and needs no edits beyond visibility changes.

Delete the iOS original. Add `import AMUXSharedUI` on `AgentDetailView.swift` and verify it still compiles.

- [ ] **Step 5.2: Wire the popover into Mac `ComposerView`**

Modify `mac/Packages/AMUXMacUI/Sources/AMUXMacUI/Composer/ComposerView.swift`. Add `import AMUXSharedUI`. Add new state:

```swift
    @State private var slashCandidates: [SlashCommand] = []
    @State private var showSlashPopup: Bool = false
```

Wrap the existing text-field (or composer entry `TextEditor`) with `.popover(isPresented: $showSlashPopup, arrowEdge: .top) { ... }`:

```swift
            .popover(isPresented: $showSlashPopup, arrowEdge: .top) {
                SlashCommandsPopup(candidates: slashCandidates) { cmd in
                    insertCommand(cmd)
                }
                .padding(6)
            }
            .onChange(of: text) { _, newValue in
                updateSlashCandidates(from: newValue)
            }
```

Implement helpers:

```swift
    private func updateSlashCandidates(from text: String) {
        guard let agent = agent,
              let prefix = Self.slashPrefix(in: text) else {
            slashCandidates = []
            showSlashPopup = false
            return
        }
        let all = agent.availableCommands  // [SlashCommand]
        slashCandidates = prefix.isEmpty ? all : all.filter { $0.name.hasPrefix(prefix) }
        showSlashPopup = !slashCandidates.isEmpty
    }

    private static func slashPrefix(in text: String) -> String? {
        guard text.hasPrefix("/") else { return nil }
        let body = text.dropFirst()
        if body.contains(" ") { return nil }  // space closes the popup
        return String(body)
    }

    private func insertCommand(_ cmd: SlashCommand) {
        text = "/\(cmd.name) "
        showSlashPopup = false
    }
```

If `agent.availableCommands` is not currently exposed on the `Agent` model, look at `ios/Packages/AMUXCore/Sources/AMUXCore/Models/` for the schema — this field was added in the ACP slash-commands work (commit `b287681`). If it lives on `AgentDetailViewModel` instead, inject `agentVM` into `ComposerView` and read from there.

- [ ] **Step 5.3: Build both targets**

```bash
cd /Volumes/openbeta/workspace/amux/mac && xcodegen && xcodebuild -project AMUXMac.xcodeproj -scheme AMUXMac build
cd /Volumes/openbeta/workspace/amux/ios && xcodegen && xcodebuild -project AMUX.xcodeproj -scheme AMUX -destination 'platform=iOS Simulator,name=iPhone 16' build
```

- [ ] **Step 5.4: Manual test**

Launch Mac app, select a running Claude session. Type `/` in the composer — popup appears with known commands (`clear`, `compact`, …). Type `/co` — filters to commands starting with `co`. Click one — text becomes `/clear ` and popup closes. Type a space — popup closes.

- [ ] **Step 5.5: Commit**

```bash
cd /Volumes/openbeta/workspace/amux
git add ios/Packages/AMUXSharedUI/Sources/AMUXSharedUI/SlashCommandsPopup.swift mac/Packages/AMUXMacUI/Sources/AMUXMacUI/Composer/ComposerView.swift ios/Packages/AMUXUI/Sources/AMUXUI/AgentDetail/AgentDetailView.swift
git add -u
git commit -m "feat(mac): slash-commands popover in ComposerView"
```

---

## Task 6: Unified search

**Goal:** Add a top-level `.searchable` on the Mac main window. When `searchText` is non-empty, the list column renders `UnifiedSearchResultsView` with grouped Sessions / Messages / Tasks.

**Files:**
- Create: `mac/Packages/AMUXMacUI/Sources/AMUXMacUI/Search/UnifiedSearchResultsView.swift`
- Modify: `mac/Packages/AMUXMacUI/Sources/AMUXMacUI/Window/MainWindowView.swift`

---

- [ ] **Step 6.1: Implement `UnifiedSearchResultsView`**

Write `mac/Packages/AMUXMacUI/Sources/AMUXMacUI/Search/UnifiedSearchResultsView.swift`:

```swift
import SwiftUI
import SwiftData
import AMUXCore

struct UnifiedSearchResultsView: View {
    let query: String
    @Binding var selectedSessionId: String?
    @Binding var selectedTaskId: String?

    @Query private var sessions: [CollabSession]
    @Query private var agents: [Agent]
    @Query private var messages: [SessionMessage]
    @Query private var tasks: [WorkItem]

    private var lowered: String { query.lowercased() }

    private var sessionHits: [SessionHit] {
        let collab: [SessionHit] = sessions.compactMap { s in
            let title = s.title.lowercased()
            if title.contains(lowered) { return SessionHit(id: s.sessionId, title: s.title.isEmpty ? s.sessionId : s.title, subtitle: "collab") }
            return nil
        }
        let agentHits: [SessionHit] = agents.compactMap { a in
            let title = a.sessionTitle.lowercased()
            if title.contains(lowered) { return SessionHit(id: a.agentId, title: a.sessionTitle.isEmpty ? a.agentId : a.sessionTitle, subtitle: "agent") }
            return nil
        }
        return collab + agentHits
    }

    private var messageHits: [MessageHit] {
        messages.compactMap { m in
            guard !m.content.isEmpty else { return nil }
            guard m.content.localizedCaseInsensitiveContains(query) else { return nil }
            return MessageHit(id: m.messageId, sessionId: m.sessionId, preview: String(m.content.prefix(140)))
        }
    }

    private var taskHits: [WorkItem] {
        tasks.filter {
            $0.displayTitle.localizedCaseInsensitiveContains(query) ||
            $0.itemDescription.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        List {
            if !sessionHits.isEmpty {
                Section("Sessions") {
                    ForEach(sessionHits) { hit in
                        Button { selectedSessionId = hit.id; selectedTaskId = nil } label: {
                            VStack(alignment: .leading) {
                                Text(hit.title)
                                Text(hit.subtitle).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if !messageHits.isEmpty {
                Section("Messages") {
                    ForEach(messageHits) { hit in
                        Button { selectedSessionId = hit.sessionId; selectedTaskId = nil } label: {
                            VStack(alignment: .leading) {
                                Text(hit.preview).lineLimit(2)
                                Text(hit.sessionId).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if !taskHits.isEmpty {
                Section("Tasks") {
                    ForEach(taskHits, id: \.workItemId) { task in
                        Button { selectedTaskId = task.workItemId; selectedSessionId = nil } label: {
                            VStack(alignment: .leading) {
                                Text(task.displayTitle)
                                Text(task.statusLabel).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if sessionHits.isEmpty && messageHits.isEmpty && taskHits.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
    }

    struct SessionHit: Identifiable {
        let id: String
        let title: String
        let subtitle: String
    }
    struct MessageHit: Identifiable {
        let id: String
        let sessionId: String
        let preview: String
    }
}
```

- [ ] **Step 6.2: Wire `.searchable` into `MainWindowView`**

Modify `mac/Packages/AMUXMacUI/Sources/AMUXMacUI/Window/MainWindowView.swift`. Add state:

```swift
    @State private var searchText: String = ""
```

Attach `.searchable(text: $searchText, placement: .toolbar, prompt: "Search")` to the outer `NavigationSplitView`.

Replace the `list` computed property's `Group` body so that when `searchText` is non-empty, it returns:

```swift
            if !searchText.isEmpty {
                UnifiedSearchResultsView(
                    query: searchText,
                    selectedSessionId: $selectedSessionId,
                    selectedTaskId: $selectedTaskId
                )
            } else {
                // existing switch on sidebarSelection
            }
```

- [ ] **Step 6.3: Build and run**

```bash
cd /Volumes/openbeta/workspace/amux/mac && xcodegen && xcodebuild -project AMUXMac.xcodeproj -scheme AMUXMac build
```

- [ ] **Step 6.4: Manual test**

Launch Mac app, type text into the toolbar search field. Results populate in the list column grouped by Sessions / Messages / Tasks. Click a result — detail pane switches accordingly.

- [ ] **Step 6.5: Commit**

```bash
cd /Volumes/openbeta/workspace/amux
git add mac/Packages/AMUXMacUI/Sources/AMUXMacUI/Search mac/Packages/AMUXMacUI/Sources/AMUXMacUI/Window/MainWindowView.swift
git commit -m "feat(mac): unified cross-session search in main window"
```

---

## Task 7: Archived tasks disclosure

**Goal:** Add an "Archived" `DisclosureGroup` at the bottom of `TaskListColumn`, toggled via Tasks function-row context menu. Row-level unarchive action.

**Files:**
- Modify: `mac/Packages/AMUXMacUI/Sources/AMUXMacUI/Sidebar/TaskListColumn.swift`
- Modify: `mac/Packages/AMUXMacUI/Sources/AMUXMacUI/Sidebar/SidebarView.swift`

---

- [ ] **Step 7.1: Add archive-visibility state + context menu in sidebar**

In `SidebarView.swift`, add:

```swift
@SceneStorage("amux.mainWindow.archivedVisible") private var archivedVisible: Bool = false
```

Attach a context menu to the Tasks `FunctionRow`:

```swift
.contextMenu {
    Button(archivedVisible ? "Hide Archived" : "Show Archived") {
        archivedVisible.toggle()
    }
}
```

Pass `archivedVisible` down to `TaskListColumn` via a new parameter.

- [ ] **Step 7.2: Render archived group in `TaskListColumn`**

Modify `TaskListColumn.swift` to accept `let archivedVisible: Bool`. Add a second `@Query` for archived items:

```swift
@Query(filter: #Predicate<WorkItem> { $0.archived == true }, sort: \WorkItem.createdAt, order: .reverse)
private var archivedTasks: [WorkItem]
```

At the bottom of the existing list, if `archivedVisible && !archivedTasks.isEmpty`:

```swift
Section {
    DisclosureGroup("Archived (\(archivedTasks.count))") {
        ForEach(archivedTasks, id: \.workItemId) { task in
            TaskRow(task: task)
                .opacity(0.55)
                .tag(task.workItemId)
                .contextMenu {
                    Button("Unarchive") {
                        Task {
                            await teamclawService.archiveWorkItem(
                                workItemId: task.workItemId,
                                sessionId: task.sessionId,
                                archived: false
                            )
                        }
                    }
                }
        }
    }
}
```

- [ ] **Step 7.3: Build and smoke test**

```bash
cd /Volumes/openbeta/workspace/amux/mac && xcodegen && xcodebuild -project AMUXMac.xcodeproj -scheme AMUXMac build
```

Launch Mac app, right-click Tasks in sidebar → "Show Archived". Verify archived tasks appear at the bottom dimmed. Right-click one → "Unarchive" — task moves back into the live list.

- [ ] **Step 7.4: Commit**

```bash
cd /Volumes/openbeta/workspace/amux
git add mac/Packages/AMUXMacUI/Sources/AMUXMacUI/Sidebar
git commit -m "feat(mac): archived tasks disclosure in TaskListColumn"
```

---

## Task 8: Settings pairing QR (Mac as host)

**Goal:** Add a "Show invite QR for a new client" action to `AccountPreferencesView` that opens `InviteQRSheet` (a regular sheet, not a window).

**Files:**
- Create: `mac/Packages/AMUXMacUI/Sources/AMUXMacUI/Settings/InviteQRSheet.swift`
- Modify: `mac/Packages/AMUXMacUI/Sources/AMUXMacUI/Settings/AccountPreferencesView.swift`

---

- [ ] **Step 8.1: Implement `InviteQRSheet`**

Write `mac/Packages/AMUXMacUI/Sources/AMUXMacUI/Settings/InviteQRSheet.swift`:

```swift
import SwiftUI
import AMUXCore
import AMUXSharedUI

struct InviteQRSheet: View {
    let teamclawService: TeamclawService
    @Binding var isPresented: Bool

    @State private var clientName = ""
    @State private var inviteURL: String?
    @State private var isGenerating = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Invite a new client").font(.title3.weight(.semibold))
            TextField("Client name (e.g. mac-laptop)", text: $clientName)
                .textFieldStyle(.roundedBorder)

            if let inviteURL {
                QRCodeView(content: inviteURL)
                    .frame(width: 220, height: 220)
                    .frame(maxWidth: .infinity, alignment: .center)
                Text(inviteURL).font(.caption.monospaced()).textSelection(.enabled)
                HStack {
                    Button("Copy link") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(inviteURL, forType: .string)
                    }
                    Button("Regenerate") { generate() }
                }
            }

            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Close") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button(inviteURL == nil ? "Generate" : "Regenerate") { generate() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(isGenerating || clientName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 420)
    }

    private func generate() {
        let trimmed = clientName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        isGenerating = true
        errorMessage = nil
        Task {
            let result = await teamclawService.createInvite(displayName: trimmed)
            await MainActor.run {
                isGenerating = false
                if let url = result { inviteURL = url } else { errorMessage = "Invite failed." }
            }
        }
    }
}
```

This reuses the `TeamclawService.createInvite` RPC added in Task 4. If that task hasn't landed yet, gate this on it.

- [ ] **Step 8.2: Host the sheet in `AccountPreferencesView`**

Modify `AccountPreferencesView.swift`. Add:

```swift
@State private var showInviteQR = false
```

Add a button somewhere inside the form (at the bottom of the account section):

```swift
Button("Show invite QR for a new client…") {
    showInviteQR = true
}
.sheet(isPresented: $showInviteQR) {
    InviteQRSheet(teamclawService: teamclawService, isPresented: $showInviteQR)
}
```

`AccountPreferencesView` needs a `teamclawService: TeamclawService` parameter — thread it from `SettingsScene` where the view is instantiated.

- [ ] **Step 8.3: Build and smoke test**

```bash
cd /Volumes/openbeta/workspace/amux/mac && xcodegen && xcodebuild -project AMUXMac.xcodeproj -scheme AMUXMac build
```

Open `AMUX → Settings…` → Account tab → click "Show invite QR for a new client…" → sheet opens, type a name, click Generate → QR + URL appear.

- [ ] **Step 8.4: Commit**

```bash
cd /Volumes/openbeta/workspace/amux
git add mac/Packages/AMUXMacUI/Sources/AMUXMacUI/Settings
git commit -m "feat(mac): invite QR sheet in Account preferences"
```

---

## Task 9: Connection banner overlay

**Goal:** Lift the body of iOS `ConnectionBannerOverlay` into `AMUXSharedUI` as a stateless `ConnectionBanner`. Host it in Mac `MainWindowView` as a top-edge overlay, bound to `connectionMonitor.daemonOnline` + `mqtt.connectionState`.

**Files:**
- Create: `ios/Packages/AMUXSharedUI/Sources/AMUXSharedUI/ConnectionBanner.swift`
- Modify: `ios/Packages/AMUXUI/Sources/AMUXUI/Root/ConnectionBannerOverlay.swift`
- Modify: `mac/Packages/AMUXMacUI/Sources/AMUXMacUI/Window/MainWindowView.swift`

---

- [ ] **Step 9.1: Create shared stateless `ConnectionBanner`**

Write `ios/Packages/AMUXSharedUI/Sources/AMUXSharedUI/ConnectionBanner.swift`:

```swift
import SwiftUI
import AMUXCore

public struct ConnectionBanner: View {
    public enum State: Equatable {
        case hidden
        case reconnecting
        case disconnected
        case daemonOffline
    }

    let state: State
    let onReconnect: (() -> Void)?

    public init(state: State, onReconnect: (() -> Void)? = nil) {
        self.state = state
        self.onReconnect = onReconnect
    }

    public var body: some View {
        switch state {
        case .hidden:
            EmptyView()
        case .reconnecting:
            banner(icon: "arrow.triangle.2.circlepath", text: "Reconnecting…", color: .yellow)
        case .disconnected:
            Button { onReconnect?() } label: {
                banner(icon: "bolt.slash.fill", text: "Not Connected · Click to reconnect", color: .red)
            }
            .buttonStyle(.plain)
        case .daemonOffline:
            banner(icon: "desktopcomputer", text: "Daemon Offline", color: .orange)
        }
    }

    private func banner(icon: String, text: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
            Text(text).font(.subheadline.weight(.medium))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .foregroundStyle(.white)
        .background(color, in: Capsule())
        .padding(.top, 10)
    }
}

public extension ConnectionBanner.State {
    static func from(connectionState: MQTTConnectionState, daemonOnline: Bool) -> Self {
        switch connectionState {
        case .reconnecting: return .reconnecting
        case .disconnected: return .disconnected
        default: return daemonOnline ? .hidden : .daemonOffline
        }
    }
}
```

If the actual enum values on `MQTTConnectionState` differ, adjust the `switch`. Reference `ios/Packages/AMUXCore/Sources/AMUXCore/MQTT/` for the real type.

- [ ] **Step 9.2: Rewire iOS `ConnectionBannerOverlay`**

Replace the entire contents of `ios/Packages/AMUXUI/Sources/AMUXUI/Root/ConnectionBannerOverlay.swift` (including the private inner `ConnectionBanner` struct at line ~20, which is superseded by the shared `ConnectionBanner`) with a thin wrapper:

```swift
import SwiftUI
import AMUXCore
import AMUXSharedUI

public struct ConnectionBannerOverlay: View {
    let mqtt: MQTTService
    let connectionMonitor: ConnectionMonitor
    var onReconnect: (() -> Void)?

    public init(mqtt: MQTTService, connectionMonitor: ConnectionMonitor, onReconnect: (() -> Void)? = nil) {
        self.mqtt = mqtt
        self.connectionMonitor = connectionMonitor
        self.onReconnect = onReconnect
    }

    public var body: some View {
        VStack(spacing: 0) {
            ConnectionBanner(
                state: .from(connectionState: mqtt.connectionState, daemonOnline: connectionMonitor.daemonOnline),
                onReconnect: onReconnect
            )
            Spacer(minLength: 0)
        }
        .allowsHitTesting(mqtt.connectionState == .disconnected)
    }
}
```

- [ ] **Step 9.3: Host `ConnectionBanner` in Mac `MainWindowView`**

Modify `MainWindowView.swift`. Import `AMUXSharedUI`. After the `NavigationSplitView { ... }` closure, attach:

```swift
.overlay(alignment: .top) {
    ConnectionBanner(
        state: .from(
            connectionState: shared.mqtt?.connectionState ?? .disconnected,
            daemonOnline: shared.monitor?.daemonOnline ?? true
        ),
        onReconnect: { Task { await shared.reconnect(pairing: pairing) } }
    )
    .allowsHitTesting(shared.mqtt?.connectionState == .disconnected)
}
```

If `SharedConnection` doesn't expose `reconnect(pairing:)`, add it — forward to `MQTTService.disconnect()` + `connectIfNeeded(pairing:)`.

- [ ] **Step 9.4: Build both targets + test**

```bash
cd /Volumes/openbeta/workspace/amux/mac && xcodegen && xcodebuild -project AMUXMac.xcodeproj -scheme AMUXMac build
cd /Volumes/openbeta/workspace/amux/ios && xcodegen && xcodebuild -project AMUX.xcodeproj -scheme AMUX -destination 'platform=iOS Simulator,name=iPhone 16' build
xcodebuild -project /Volumes/openbeta/workspace/amux/mac/AMUXMac.xcodeproj -scheme AMUXMac -destination 'platform=macOS' test
```

- [ ] **Step 9.5: Manual test**

Launch Mac app. Kill the daemon — banner appears with "Daemon Offline" → restart daemon → banner disappears. Temporarily break MQTT (block outbound port or kill the broker) — reconnecting banner appears; click "Not Connected" — banner requests reconnect.

- [ ] **Step 9.6: Commit**

```bash
cd /Volumes/openbeta/workspace/amux
git add ios/Packages/AMUXSharedUI/Sources/AMUXSharedUI/ConnectionBanner.swift ios/Packages/AMUXUI/Sources/AMUXUI/Root/ConnectionBannerOverlay.swift mac/Packages/AMUXMacUI/Sources/AMUXMacUI/Window/MainWindowView.swift
git add -u
git commit -m "feat(mac): top-edge ConnectionBanner overlay in MainWindow"
```

---

## Final verification

- [ ] **Full build + test (both platforms)**

```bash
cd /Volumes/openbeta/workspace/amux/mac && xcodegen && xcodebuild -project AMUXMac.xcodeproj -scheme AMUXMac build
cd /Volumes/openbeta/workspace/amux/ios && xcodegen && xcodebuild -project AMUX.xcodeproj -scheme AMUX -destination 'platform=iOS Simulator,name=iPhone 16' build
xcodebuild -project /Volumes/openbeta/workspace/amux/mac/AMUXMac.xcodeproj -scheme AMUXMac -destination 'platform=macOS' test
```

- [ ] **QA checklist**

Walk through every landing against the spec's `Feature designs` section and confirm each feature works end-to-end on a real daemon:

1. Task Detail — open task, change status, edit via editor window, create new task from sidebar "+".
2. Permission banner — request arrives with app foreground → inline; app backgrounded → UN notification; Grant/Deny via either path resolves the same request.
3. Members window — opens via sidebar button and `Cmd+Shift+M`; invite button opens Invite window; QR + link generation works.
4. Slash commands — popover appears on `/`, filters, inserts, dismisses.
5. Search — toolbar search produces grouped results; selecting one drives detail pane.
6. Archived tasks — toggle via sidebar context menu; unarchive via row context menu.
7. Invite QR — Settings → Account → Show invite QR → QR + URL render.
8. Connection banner — daemon offline / MQTT disconnected states render appropriately.

- [ ] **Done — tag the work**

```bash
cd /Volumes/openbeta/workspace/amux
git log --oneline -15  # confirm all 9 landings are present
```

---

## References

- Design spec: `docs/superpowers/specs/2026-04-19-macos-ios-parity-design.md`
- ACP slash-commands spec (related): `docs/superpowers/specs/2026-04-19-acp-slash-commands-design.md`
- iOS task detail spec (related): `docs/superpowers/specs/2026-04-19-ios-task-detail-design.md`
- TeamclawService RPC surface: `ios/Packages/AMUXCore/Sources/AMUXCore/TeamclawService.swift`
- iOS permission banner source: `ios/Packages/AMUXUI/Sources/AMUXUI/AgentDetail/PermissionBannerView.swift`
- iOS slash-commands popup source: `ios/Packages/AMUXUI/Sources/AMUXUI/AgentDetail/SlashCommandsPopup.swift`
- iOS connection overlay source: `ios/Packages/AMUXUI/Sources/AMUXUI/Root/ConnectionBannerOverlay.swift`
