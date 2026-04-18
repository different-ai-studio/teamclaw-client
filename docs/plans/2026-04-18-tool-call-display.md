# Tool Call Display Improvements Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Collapse completed tool calls into compact lines and summary bars to reduce visual noise in the agent event feed.

**Architecture:** View-layer only change in the AMUXUI package. Replace `MergedToolCallView` and the same-name grouping logic with a new "tool run" grouping that collapses all consecutive completed tools regardless of name. Add `CompactToolLine` and `ToolRunSummaryBar` views.

**Tech Stack:** SwiftUI, iOS 17+

---

### Task 1: Add hasDetails filter and CompactToolLine view

**Files:**
- Modify: `ios/Packages/AMUXUI/Sources/AMUXUI/AgentDetail/ToolCallView.swift:6-128`

- [ ] **Step 1: Add hasDetails computed property to ToolCallView**

In `ToolCallView`, add a computed property after line 11 (`@State private var isExpanded = false`) and update `body` to use it:

```swift
// Add after line 11
private var hasDetails: Bool {
    let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
    return !trimmed.isEmpty && trimmed != "{}" && trimmed != "null"
}
```

Then update the `body` to use `hasDetails` instead of `!description.isEmpty`:
- Line 22: change `withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }` to `if hasDetails { withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() } }`
- Line 26: wrap the chevron `Image` in `if hasDetails { ... }`
- Line 41: change `if !description.isEmpty && !isExpanded` to `if hasDetails && !isExpanded`
- Line 58: change `if isExpanded && !description.isEmpty` to `if isExpanded && hasDetails`

- [ ] **Step 2: Add CompactToolLine view**

Add this view after the `ToolCallView` struct (before the `MergedToolCallView` section around line 129):

```swift
// MARK: - CompactToolLine

public struct CompactToolLine: View {
    let event: AgentEvent
    @State private var showDetail = false

    private var toolName: String { event.toolName ?? "" }
    private var description: String { event.text ?? "" }
    private var succeeded: Bool { event.success != false }

    private var hasDetails: Bool {
        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed != "{}" && trimmed != "null"
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: succeeded ? "checkmark" : "xmark")
                    .font(.system(size: 9))
                    .foregroundStyle(succeeded ? .green : .red)

                Image(systemName: ToolCallView.icon(for: toolName))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)

                Text(ToolCallView.shortName(for: toolName.isEmpty ? (event.toolId ?? "") : toolName))
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 1)
            .contentShape(Rectangle())
            .onTapGesture {
                if hasDetails {
                    withAnimation(.easeInOut(duration: 0.15)) { showDetail.toggle() }
                }
            }

            if showDetail && hasDetails {
                Text(description)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 4)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}
```

- [ ] **Step 3: Build to verify**

Run:
```bash
cd /Volumes/openbeta/workspace/amux/ios && xcodebuild -project AMUX.xcodeproj -scheme AMUX -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
cd /Volumes/openbeta/workspace/amux && git add ios/Packages/AMUXUI/Sources/AMUXUI/AgentDetail/ToolCallView.swift
git commit -m "feat(ios): add CompactToolLine view and hasDetails filter"
```

---

### Task 2: Add ToolRunSummaryBar and replace grouping logic

**Files:**
- Modify: `ios/Packages/AMUXUI/Sources/AMUXUI/AgentDetail/ToolCallView.swift:130-288`

- [ ] **Step 1: Replace MergedToolCallView and MergedToolDetailRow with ToolRunSummaryBar**

Delete the entire `MergedToolCallView` struct (lines ~130-203) and `MergedToolDetailRow` struct (lines ~206-235). Replace them with:

```swift
// MARK: - ToolRunSummaryBar

public struct ToolRunSummaryBar: View {
    let events: [AgentEvent]
    @State private var isExpanded = false

    private var count: Int { events.count }

    private var hasFailure: Bool {
        events.contains { $0.success == false }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .foregroundStyle(.secondary)

                    Image(systemName: "wrench")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text("\(count) tools completed")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(.primary)

                    Spacer()

                    if hasFailure {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.green)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(events, id: \.id) { event in
                        CompactToolLine(event: event)
                    }
                }
                .padding(.bottom, 4)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
```

- [ ] **Step 2: Replace GroupedEvent enum and groupEvents function**

Replace the existing `GroupedEvent` enum and `groupEvents()` function (lines ~240-288) with:

```swift
// MARK: - Event Grouping

public enum GroupedEvent: Identifiable {
    case single(AgentEvent)
    case toolRun(id: String, events: [AgentEvent])

    public var id: String {
        switch self {
        case .single(let e): e.id
        case .toolRun(let id, _): id
        }
    }
}

/// Groups consecutive completed tool_use events into tool runs.
/// Running/incomplete tools and all non-tool events remain as singles.
public func groupEvents(_ events: [AgentEvent]) -> [GroupedEvent] {
    var result: [GroupedEvent] = []
    var i = 0
    while i < events.count {
        let event = events[i]

        // Only group completed tool_use events
        if event.eventType == "tool_use", event.isComplete {
            var group = [event]
            var j = i + 1
            while j < events.count,
                  events[j].eventType == "tool_use",
                  events[j].isComplete {
                group.append(events[j])
                j += 1
            }

            if group.count >= 3 {
                let groupId = "toolrun-\(group.first!.id)"
                result.append(.toolRun(id: groupId, events: group))
            } else {
                for e in group { result.append(.single(e)) }
            }
            i = j
        } else {
            result.append(.single(event))
            i += 1
        }
    }
    return result
}
```

- [ ] **Step 3: Build to verify**

Run:
```bash
cd /Volumes/openbeta/workspace/amux/ios && xcodebuild -project AMUX.xcodeproj -scheme AMUX -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build 2>&1 | tail -5
```
Expected: Build will FAIL because `AgentDetailView.swift` still references `.mergedTools` and `MergedToolCallView`. This is expected — Task 3 fixes it.

- [ ] **Step 4: Commit (work in progress)**

```bash
cd /Volumes/openbeta/workspace/amux && git add ios/Packages/AMUXUI/Sources/AMUXUI/AgentDetail/ToolCallView.swift
git commit -m "wip(ios): replace MergedToolCallView with ToolRunSummaryBar and new grouping"
```

---

### Task 3: Update AgentDetailView and EventFeedView to use new grouping

**Files:**
- Modify: `ios/Packages/AMUXUI/Sources/AMUXUI/AgentDetail/AgentDetailView.swift:98-111`
- Modify: `ios/Packages/AMUXUI/Sources/AMUXUI/AgentDetail/EventFeedView.swift:115-133`

- [ ] **Step 1: Update AgentDetailView ForEach**

In `AgentDetailView.swift`, find the `ForEach` switch statement (around lines 98-111). Replace the `.mergedTools` case:

```swift
// Replace this:
case .mergedTools(let id, let toolName, let events):
    MergedToolCallView(toolName: toolName, events: events)
        .padding(.horizontal, 16)
        .padding(.vertical, 2)
        .id(id)

// With this:
case .toolRun(let id, let events):
    ToolRunSummaryBar(events: events)
        .padding(.horizontal, 16)
        .padding(.vertical, 2)
        .id(id)
```

- [ ] **Step 2: Update EventFeedView toolUseBlock to use CompactToolLine for completed tools**

In `EventFeedView.swift`, replace the `toolUseBlock` computed property (around lines 115-133):

```swift
// Replace entire toolUseBlock with:
private var toolUseBlock: some View {
    Group {
        if event.isComplete == true {
            CompactToolLine(event: event)
        } else {
            let status: String = "running"
            ToolCallView(
                toolName: event.toolName ?? "Unknown",
                toolId: event.toolId ?? "",
                description: event.text ?? "",
                status: status
            )
            .padding(.horizontal, 16)
            .padding(.vertical, 2)
        }
    }
    .contextMenu {
        MessageContextMenu(text: event.text ?? "")
    }
}
```

- [ ] **Step 3: Build to verify**

Run:
```bash
cd /Volumes/openbeta/workspace/amux/ios && xcodebuild -project AMUX.xcodeproj -scheme AMUX -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Install and verify visually**

```bash
xcrun simctl install booted ~/Library/Developer/Xcode/DerivedData/AMUX-*/Build/Products/Debug-iphonesimulator/AMUX.app
xcrun simctl launch booted tech.teamclaw.mobile
```

Take a screenshot and verify:
- Running tools show as full cards with spinner
- 1-2 completed tools in a row show as compact single lines
- 3+ completed tools in a row show as a collapsible summary bar
- No `{}` details shown anywhere

- [ ] **Step 5: Commit**

```bash
cd /Volumes/openbeta/workspace/amux && git add ios/Packages/AMUXUI/Sources/AMUXUI/AgentDetail/AgentDetailView.swift ios/Packages/AMUXUI/Sources/AMUXUI/AgentDetail/EventFeedView.swift
git commit -m "feat(ios): hybrid tool call display with compact lines and summary bars"
```
