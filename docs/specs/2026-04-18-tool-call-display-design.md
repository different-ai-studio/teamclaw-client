# Tool Call Display Improvements

> **For agentic workers:** This spec covers a view-layer-only change in the iOS AMUXUI package.

**Goal:** Reduce visual noise from tool calls in the agent event feed by collapsing completed tools and making them compact.

**Problem:** Tool calls dominate the conversation view. Each completed tool renders as a full card with padding, empty `{}` details are shown, and completed tools have the same visual weight as the running tool. Consecutive tool calls push actual assistant output off screen.

## Grouping Logic

Replace the current `groupEvents()` function in `ToolCallView.swift`. The current implementation only merges consecutive completed tools **of the same name**. The new implementation groups **all** consecutive completed `tool_use` events into a single "tool run", regardless of tool name.

A **tool run** is a maximal consecutive sequence of completed `tool_use` events. The sequence breaks at any non-tool-use event (user_prompt, output, thinking, error, permission_request, todo_update) or at a running/incomplete tool_use.

The `GroupedEvent` enum changes:
- Remove `.mergedTools` case
- Add `.toolRun(id: String, events: [AgentEvent])` case

A running (incomplete) `tool_use` is always `.single` — never grouped into a tool run.

## Display Rules

Given a tool run containing N completed tools:

| N | Display |
|---|---------|
| 1 | Single `CompactToolLine` |
| 2 | Two `CompactToolLine` views |
| >= 3 | `ToolRunSummaryBar` showing count; tap expands to show all as `CompactToolLine` views |

## New Views

### CompactToolLine

A single-line replacement for the current `ToolCallView` card, used for completed tools only:

- Layout: `[status icon] [tool icon] [display name]`
- Status icon: green checkmark for success, red X for failure
- Tool icon: reuse existing `ToolCallView.icon(for:)` static method
- Display name: reuse existing `ToolCallView.shortName(for:)` static method
- No background card, no padding beyond horizontal 16
- No chevron, no details section by default
- If description is non-empty and not trivial (`{}`, `null`, whitespace-only): tapping the line toggles a details overlay below it
- Vertical padding: 1pt (compact)

### ToolRunSummaryBar

A compact collapsible row for tool runs with 3+ tools:

- Layout: `[chevron] [wrench icon] [count] tools completed [overall status]`
- Overall status: green checkmark if all succeeded, orange warning if any failed
- Chevron rotates on expand
- Background: `Color(.systemGray6)` with rounded rect, same as current tool cards
- Horizontal padding: 16, vertical padding: 2
- Expanded state: shows each tool as a `CompactToolLine` below the header

### Running tool display

No change — a running (incomplete) tool_use continues to render as the current `ToolCallView` card with spinner.

## Empty Details Fix

Add a `hasDetails` check that filters out trivial descriptions:

```swift
let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
let hasDetails = !trimmed.isEmpty && trimmed != "{}" && trimmed != "null"
```

Apply this in:
- `CompactToolLine`: only show expandable details when `hasDetails` is true
- `ToolCallView` (for running tools): hide chevron and details section when `!hasDetails`

## Files Changed

- `ToolCallView.swift` — Add `CompactToolLine`, `ToolRunSummaryBar`. Replace `groupEvents()` logic. Remove `MergedToolCallView` and `MergedToolDetailRow`. Add `hasDetails` to `ToolCallView`.
- `EventFeedView.swift` — Update `toolUseBlock` and the `ForEach` that renders `GroupedEvent` to handle `.toolRun` case instead of `.mergedTools`.

## Files NOT Changed

- No model changes (AgentEvent, Agent)
- No viewmodel changes (AgentDetailViewModel)
- No daemon changes
- No proto changes
