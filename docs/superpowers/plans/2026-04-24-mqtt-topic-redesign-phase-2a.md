# MQTT Topic Redesign — Phase 2a Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** iOS switches its runtime state subscriptions, event subscriptions, and command publishes from the legacy `agent/{id}/*` topics to the new `runtime/{id}/*` topics. `ConnectionMonitor` dual-subscribes `device/{id}/status` + `device/{id}/state` with offline-wins merge (per the spec's LWT compatibility rule from Phase 1a). All other iOS wire behavior stays identical — peers/workspaces still read from retained topics, collab operations still use `/collab`, `AcpCommand::StartAgent` still goes through `CommandEnvelope`, `user/{actor}/notify` not yet subscribed (gated on Phase 1d), SwiftData `Agent` model stays `Agent`. Zero user-visible behavior change intended — just a wire cutover for the state/event/command traffic.

**Architecture:** Daemon has dual-published to both old (`agent/{id}/state`) and new (`runtime/{id}/state`) retained topics since Phase 1a (commit `b6e9f337`), and dual-subscribed to both `agent/+/commands` and `runtime/+/commands` wildcards (commit `e6ed250a`). That means iOS can switch its SUBSCRIBE side to new-only without losing data and its PUBLISH side to new-only without the daemon missing the commands. Phase 2a executes that switch. `ConnectionMonitor` is the one exception: it dual-subscribes status + state per spec because LWT only fires on `status` until Phase 3, and the merge rule is offline-wins so crash detection stays reliable while the new `state` topic is exercised.

**Tech Stack:** Swift, swift-protobuf, mqtt-nio (or CocoaMQTT — whichever `MQTTService` wraps). No new dependencies.

**Reference:** `docs/superpowers/specs/2026-04-24-mqtt-topic-redesign-design.md` — "Migration Plan → Phase 2" and "Phase 1 iOS strategy (decided)" note about offline-wins LWT merge.

**Out of scope for Phase 2a:**
- **Peers + workspaces RPC switchover.** iOS still reads retained `device/{id}/peers` and `device/{id}/workspaces` topics. Phase 2b replaces these with `FetchPeers` / `FetchWorkspaces` RPCs + `device/{id}/notify` invalidation hints.
- **Collab operations RPC switchover.** iOS still publishes `PeerAnnounce` / `AddWorkspace` / `RemoveMember` / etc. to `device/{id}/collab`. Phase 2b switches them to `rpc/req`.
- **`RuntimeStart` RPC adoption.** iOS still spawns runtimes via `AcpCommand::StartAgent` wrapped in `CommandEnvelope`. Phase 2c switches to the new `RuntimeStart` RPC with the STARTING/ACTIVE lifecycle state machine introduced in Phase 1c.
- **SwiftData `Agent` → `Runtime` rename.** Phase 2d does the local-model rename (destructive reset per the spec, since runtime history is recoverable from MQTT retained + Supabase).
- **`user/{actor}/notify` subscription.** Gated on Phase 1d (Supabase `user_inbox` table + EMQX JWT auth). Not subscribed in Phase 2a.
- **Legacy `MQTTTopics.swift` method deletion.** Legacy methods (`agentState`, `agentStateWildcard`, `agentStatePrefix`, `agentEvents`, `agentCommands`, `devicePeers`, `deviceWorkspaces`, `deviceCollab`) stay in the file for Phases 2b–2c to migrate other call sites. Phase 2d deletes the ones that are truly unused.

---

## File Structure

**Swift files edited:**
- `ios/Packages/AMUXCore/Sources/AMUXCore/MQTT/MQTTTopics.swift` — add new methods: `deviceState`, `runtimeState`, `runtimeStateWildcard`, `runtimeStatePrefix`, `runtimeEvents`, `runtimeCommands`, `runtimeCommandsWildcard`, `userNotify` (builder only — not subscribed yet).
- `ios/Packages/AMUXCore/Sources/AMUXCore/ConnectionMonitor.swift` — dual-subscribe `deviceStatus` + `deviceState`, merge with offline-wins rule.
- `ios/Packages/AMUXCore/Sources/AMUXCore/ViewModels/SessionListViewModel.swift` — switch state wildcard subscription from `agentStateWildcard` to `runtimeStateWildcard` (single-path). Update prefix/suffix string matching to match the new topic shape.
- `ios/Packages/AMUXCore/Sources/AMUXCore/ViewModels/AgentDetailViewModel.swift` — switch events subscription from `agentEvents` to `runtimeEvents`; switch command publish from `agentCommands` to `runtimeCommands`.

**Behavior at end of Phase 2a:**
- iOS subscribes to `device/{id}/runtime/+/state` wildcard — NOT to `device/{id}/agent/+/state`.
- iOS subscribes to `device/{id}/runtime/{id}/events` for the foreground agent — NOT to `device/{id}/agent/{id}/events`.
- iOS publishes commands to `device/{id}/runtime/{id}/commands` — NOT to `device/{id}/agent/{id}/commands`. Daemon receives them via its `runtime/+/commands` wildcard (wired in Phase 1a commit `e6ed250a`).
- `ConnectionMonitor` receives LWT crash-offline signal on legacy `status` + normal-transition updates on new `state`. Merge: if either topic reads offline, device is offline.
- All other traffic unchanged: peers / workspaces / collab / `AcpCommand::StartAgent` publish paths are identical to Phase 1c HEAD.
- No SwiftData migration, no user-visible feature change.

**Daemon requirement:** Phase 1a or later. This plan's wire cutover assumes the daemon dual-publishes/subscribes. On pre-Phase-1a daemons, an iOS build with Phase 2a changes would stop receiving state/events entirely — confirm the paired daemon is at HEAD before shipping an iOS build with these changes.

---

## Task 1: Verify green baseline

**Files:** none (verification only)

- [ ] **Step 1: Confirm daemon + iOS green at Phase 1c final**

```bash
cd /Volumes/openbeta/workspace/amux/daemon && set -a && source .env && set +a && cargo build 2>&1 | tail -3 && cargo test --no-fail-fast 2>&1 | grep "cargo test:" | tail -1
cd /Volumes/openbeta/workspace/amux/ios && xcodebuild -project AMUX.xcodeproj -scheme AMUX -destination 'generic/platform=iOS' -configuration Debug build CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "BUILD SUCCEEDED|BUILD FAILED" | head -2
```
Expected: daemon 104+ tests pass, iOS `** BUILD SUCCEEDED **`.

- [ ] **Step 2: Confirm HEAD**

```bash
cd /Volumes/openbeta/workspace/amux && git log --oneline -1
```
Expected: `91aea53f feat(rpc): implement RuntimeStart handler with STARTING/ACTIVE lifecycle` or later.

No commit in this task.

---

## Task 2: Add new path builders to `MQTTTopics.swift`

**Files:**
- Modify: `ios/Packages/AMUXCore/Sources/AMUXCore/MQTT/MQTTTopics.swift`

Mirror the Rust `Topics::*` builders added in Phase 1a Task 3. Legacy methods stay — Phase 2b–2d migrate and delete them separately.

- [ ] **Step 1: Add new builder methods**

In `/Volumes/openbeta/workspace/amux/ios/Packages/AMUXCore/Sources/AMUXCore/MQTT/MQTTTopics.swift`, append the following methods to the `public enum MQTTTopics { ... }` body (just before the closing `}`):

```swift
    // ─── Phase 2 — new-architecture paths (dual-published by daemon since Phase 1a) ───

    /// New device-scoped retained state topic. LWT migrates here in Phase 3;
    /// until then Phase 1a daemon mirror-publishes normal transitions here and
    /// keeps LWT firing on /status. ConnectionMonitor dual-subscribes.
    public static func deviceState(teamID: String, deviceID: String) -> String {
        "\(deviceBase(teamID: teamID, deviceID: deviceID))/state"
    }

    /// Per-runtime retained state. Payload is the same `Amux_RuntimeInfo` that
    /// `agentState(...)` carries — only the wire path differs.
    public static func runtimeState(teamID: String, deviceID: String, runtimeID: String) -> String {
        "\(deviceBase(teamID: teamID, deviceID: deviceID))/runtime/\(runtimeID)/state"
    }

    public static func runtimeStateWildcard(teamID: String, deviceID: String) -> String {
        "\(deviceBase(teamID: teamID, deviceID: deviceID))/runtime/+/state"
    }

    public static func runtimeStatePrefix(teamID: String, deviceID: String) -> String {
        "\(deviceBase(teamID: teamID, deviceID: deviceID))/runtime/"
    }

    public static func runtimeEvents(teamID: String, deviceID: String, runtimeID: String) -> String {
        "\(deviceBase(teamID: teamID, deviceID: deviceID))/runtime/\(runtimeID)/events"
    }

    public static func runtimeCommands(teamID: String, deviceID: String, runtimeID: String) -> String {
        "\(deviceBase(teamID: teamID, deviceID: deviceID))/runtime/\(runtimeID)/commands"
    }

    public static func runtimeCommandsWildcard(teamID: String, deviceID: String) -> String {
        "\(deviceBase(teamID: teamID, deviceID: deviceID))/runtime/+/commands"
    }

    /// Team-scoped user notify channel. Requires broker JWT auth before use
    /// (Phase 1d prerequisite); builder is available now so Phase 2 code can
    /// reference it, but no subscribe happens until 1d ships.
    public static func userNotify(teamID: String, actorID: String) -> String {
        "\(teamclawBase(teamID: teamID))/user/\(actorID)/notify"
    }
```

- [ ] **Step 2: Verify iOS compiles**

```bash
cd /Volumes/openbeta/workspace/amux/ios && xcodebuild -project AMUX.xcodeproj -scheme AMUX -destination 'generic/platform=iOS' -configuration Debug build CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "BUILD SUCCEEDED|BUILD FAILED|error:" | head -5
```
Expected: `** BUILD SUCCEEDED **`. Pure additive change — cannot break existing callers.

- [ ] **Step 3: Commit**

```bash
cd /Volumes/openbeta/workspace/amux && git add ios/Packages/AMUXCore/Sources/AMUXCore/MQTT/MQTTTopics.swift && git commit -m "$(cat <<'EOF'
feat(ios): add Phase 2 MQTTTopics path builders (runtime/*, deviceState, userNotify)

Mirrors the Rust Topics builders added in Phase 1a. Legacy methods
(agentState, agentStateWildcard, agentEvents, agentCommands, etc.)
stay for now — Tasks 3-5 in this plan migrate the call sites.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: `ConnectionMonitor` — dual-subscribe status + state with offline-wins

**Files:**
- Modify: `ios/Packages/AMUXCore/Sources/AMUXCore/ConnectionMonitor.swift`

Per spec's Phase 1 decision: iOS subscribes to BOTH `device/{id}/status` and `device/{id}/state` during the Phases 1–3 compat window. LWT fires only on `status`, so `status` is the crash-offline signal. `state` gets normal-transition updates (and in Phase 3 takes over LWT). Merge rule: offline wins — if either topic currently reads `online: false`, treat the device as offline.

- [ ] **Step 1: Read the current `ConnectionMonitor` implementation**

```bash
cat /Volumes/openbeta/workspace/amux/ios/Packages/AMUXCore/Sources/AMUXCore/ConnectionMonitor.swift
```

Identify:
- How `ConnectionMonitor` subscribes to `MQTTTopics.deviceStatus(...)` today
- Where it decodes `Amux_DeviceState` (was `Amux_DeviceStatus` before Phase 0 Task 4) payloads
- Where it publishes a `daemonOnline: Bool` property for UI

- [ ] **Step 2: Modify `ConnectionMonitor` to dual-subscribe and merge**

The exact refactor depends on the current code shape. Below is the canonical pattern — adapt names / @Observable properties to match what's there:

Introduce two internal state fields:

```swift
    private var statusOnline: Bool? = nil
    private var stateOnline: Bool? = nil
```

Where the existing subscribe lives, subscribe to BOTH topics:

```swift
        try await mqtt.subscribe(MQTTTopics.deviceStatus(teamID: teamID, deviceID: deviceID))
        try await mqtt.subscribe(MQTTTopics.deviceState(teamID: teamID, deviceID: deviceID))
```

Where the existing message stream parses, add a branch on topic suffix:

```swift
            for await msg in stream {
                if msg.topic.hasSuffix("/status") {
                    if msg.payload.isEmpty {
                        // Empty retained = topic cleared; treat as offline.
                        statusOnline = false
                    } else if let state = try? ProtoMQTTCoder.decode(Amux_DeviceState.self, from: msg.payload) {
                        statusOnline = state.online
                    }
                } else if msg.topic.hasSuffix("/state") {
                    if msg.payload.isEmpty {
                        stateOnline = false
                    } else if let state = try? ProtoMQTTCoder.decode(Amux_DeviceState.self, from: msg.payload) {
                        stateOnline = state.online
                    }
                }
                daemonOnline = mergeOfflineWins(statusOnline, stateOnline)
            }
```

And the helper:

```swift
    /// Offline-wins merge per Phase 1a spec decision. If either source reports
    /// offline, the device is offline. If both are nil (no data yet), treat as
    /// unknown → online: false (conservative).
    private func mergeOfflineWins(_ s: Bool?, _ t: Bool?) -> Bool {
        switch (s, t) {
        case (false, _), (_, false): return false  // either offline → offline
        case (true, _), (_, true): return true      // neither offline, some data → online
        default: return false                        // no data yet
        }
    }
```

**Adapt to match existing code.** The helper may need to be a free function or `@MainActor`-scoped depending on where `daemonOnline` lives. Field names (`statusOnline`, `stateOnline`) are illustrative — if the existing file uses a different style (e.g., a single `lastStatusPayload: Amux_DeviceState?`), follow that style instead.

- [ ] **Step 3: Verify iOS compiles**

```bash
cd /Volumes/openbeta/workspace/amux/ios && xcodebuild -project AMUX.xcodeproj -scheme AMUX -destination 'generic/platform=iOS' -configuration Debug build CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "BUILD SUCCEEDED|BUILD FAILED|error:" | head -5
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
cd /Volumes/openbeta/workspace/amux && git add ios/Packages/AMUXCore/Sources/AMUXCore/ConnectionMonitor.swift && git commit -m "$(cat <<'EOF'
feat(ios): ConnectionMonitor dual-subscribes device/status + device/state

Subscribes to both topics in the Phase 1-3 compat window and merges
with offline-wins: if either topic reads offline, the device is offline.
Status carries LWT crash-offline; state carries normal transitions plus
(from Phase 3) LWT. Spec "Phase 1 iOS strategy (decided)".

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: `SessionListViewModel` — switch state wildcard to runtime path

**Files:**
- Modify: `ios/Packages/AMUXCore/Sources/AMUXCore/ViewModels/SessionListViewModel.swift`

Currently subscribes to `agentStateWildcard` (~line 97). Switch to `runtimeStateWildcard` — single-path, new only. The retained payload (`Amux_RuntimeInfo`) is identical on both paths per Phase 1a Task 4 dual-publish, so no decode logic changes.

- [ ] **Step 1: Replace the wildcard subscription + prefix/suffix string matching**

In `/Volumes/openbeta/workspace/amux/ios/Packages/AMUXCore/Sources/AMUXCore/ViewModels/SessionListViewModel.swift`, find the existing block around line 66-68:

```swift
        let agentStatePrefix = MQTTTopics.agentStatePrefix(teamID: teamID, deviceID: deviceId)
        let agentStateSuffix = "/state"
        let agentStateWildcard = MQTTTopics.agentStateWildcard(teamID: teamID, deviceID: deviceId)
```

Replace with:

```swift
        let runtimeStatePrefix = MQTTTopics.runtimeStatePrefix(teamID: teamID, deviceID: deviceId)
        let runtimeStateSuffix = "/state"
        let runtimeStateWildcard = MQTTTopics.runtimeStateWildcard(teamID: teamID, deviceID: deviceId)
```

Find the subscribe call (~line 97):

```swift
                try? await mqtt.subscribe(agentStateWildcard)
```

Replace with:

```swift
                try? await mqtt.subscribe(runtimeStateWildcard)
```

Find the log line (~line 100):

```swift
                NSLog("[SessionListVM] subscribed to %@ + %@", agentStateWildcard, workspacesTopic)
```

Update the variable name:

```swift
                NSLog("[SessionListVM] subscribed to %@ + %@", runtimeStateWildcard, workspacesTopic)
```

Find the topic-prefix match (~line 114):

```swift
                    guard msg.topic.hasPrefix(agentStatePrefix),
                          msg.topic.hasSuffix(agentStateSuffix) else { continue }
```

Replace with:

```swift
                    guard msg.topic.hasPrefix(runtimeStatePrefix),
                          msg.topic.hasSuffix(runtimeStateSuffix) else { continue }
```

Find the runtime_id extraction (~line 119):

```swift
                        let agentId = String(msg.topic.dropFirst(agentStatePrefix.count).dropLast(agentStateSuffix.count))
```

Replace with:

```swift
                        let agentId = String(msg.topic.dropFirst(runtimeStatePrefix.count).dropLast(runtimeStateSuffix.count))
```

(The local variable name `agentId` stays — it's used downstream as `SwiftData Agent.agentId` which doesn't rename until Phase 2d.)

**Do NOT rename** `SwiftData Agent` references, nor the `removeAgent(agentId:...)` call, nor the `syncAgent(...)` function. This task is purely a wire-path switch.

- [ ] **Step 2: Update the stale comment on lines 61-65**

The block comment starts with:

```swift
        // Daemon fans each session out to its own retained topic
        // `device/{id}/agent/{agent}/state` (one RuntimeInfo per message) so a
        // single publish never relies on a large broker packet limit. We
        // subscribe to the wildcard and rebuild our dict as retained
        // messages arrive.
```

Update the topic example to match the new path:

```swift
        // Daemon fans each session out to its own retained topic
        // `device/{id}/runtime/{runtime}/state` (one RuntimeInfo per message)
        // so a single publish never relies on a large broker packet limit. We
        // subscribe to the wildcard and rebuild our dict as retained
        // messages arrive.
```

- [ ] **Step 3: Verify iOS compiles**

```bash
cd /Volumes/openbeta/workspace/amux/ios && xcodebuild -project AMUX.xcodeproj -scheme AMUX -destination 'generic/platform=iOS' -configuration Debug build CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "BUILD SUCCEEDED|BUILD FAILED|error:" | head -5
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
cd /Volumes/openbeta/workspace/amux && git add ios/Packages/AMUXCore/Sources/AMUXCore/ViewModels/SessionListViewModel.swift && git commit -m "$(cat <<'EOF'
feat(ios): SessionListViewModel subscribes to runtime/+/state wildcard

Switches from device/{id}/agent/+/state to device/{id}/runtime/+/state.
Payload is identical (Amux_RuntimeInfo dual-published since Phase 1a).
Local agentId variable name retained — SwiftData Agent model stays
until Phase 2d rename.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: `AgentDetailViewModel` — switch events subscribe + commands publish to runtime paths

**Files:**
- Modify: `ios/Packages/AMUXCore/Sources/AMUXCore/ViewModels/AgentDetailViewModel.swift`

Two changes:
1. Line 283 subscribes to `agentEvents(...)`. Switch to `runtimeEvents(...)`.
2. Line 582 publishes to `agentCommands(...)`. Switch to `runtimeCommands(...)`.

Payloads (`Amux_Envelope` and `Amux_CommandEnvelope`) already use the renamed `runtimeID` field from Phase 0 Task 6, so no proto-field changes needed.

- [ ] **Step 1: Replace the events subscribe**

Find the block around line 280-284:

```swift
                let eventsTopic = MQTTTopics.agentEvents(teamID: teamID, deviceID: deviceId, agentID: agent.agentId)
                ...
                try? await mqtt.subscribe(eventsTopic)
                print("[AgentDetailVM] subscribed to \(eventsTopic)")
```

(The exact structure may differ — the implementer should read the real code and adapt.)

Replace `MQTTTopics.agentEvents` with `MQTTTopics.runtimeEvents`:

```swift
                let eventsTopic = MQTTTopics.runtimeEvents(teamID: teamID, deviceID: deviceId, runtimeID: agent.agentId)
                ...
                try? await mqtt.subscribe(eventsTopic)
                print("[AgentDetailVM] subscribed to \(eventsTopic)")
```

Note: the **parameter label changes from `agentID:` to `runtimeID:`** because the new builder `runtimeEvents` uses `runtimeID` per the Phase 0 Task 6 proto field rename. The **argument value** stays `agent.agentId` — that's the SwiftData `Agent.agentId` property which is the same subprocess id, just not yet renamed locally.

- [ ] **Step 2: Replace the command publish at line 582**

Find:

```swift
        try await mqtt.publish(topic: MQTTTopics.agentCommands(teamID: teamID, deviceID: deviceId, agentID: agent.agentId), payload: data)
```

Replace with:

```swift
        try await mqtt.publish(topic: MQTTTopics.runtimeCommands(teamID: teamID, deviceID: deviceId, runtimeID: agent.agentId), payload: data)
```

Same parameter-label change (`agentID:` → `runtimeID:`), same argument value.

- [ ] **Step 3: Verify iOS compiles**

```bash
cd /Volumes/openbeta/workspace/amux/ios && xcodebuild -project AMUX.xcodeproj -scheme AMUX -destination 'generic/platform=iOS' -configuration Debug build CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "BUILD SUCCEEDED|BUILD FAILED|error:" | head -5
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
cd /Volumes/openbeta/workspace/amux && git add ios/Packages/AMUXCore/Sources/AMUXCore/ViewModels/AgentDetailViewModel.swift && git commit -m "$(cat <<'EOF'
feat(ios): AgentDetailViewModel uses runtime/{id}/events and runtime/{id}/commands

Switches the ACP events subscribe and the command publish to the new
topic paths. Daemon dual-subscribed to both path shapes since Phase 1a
(commit e6ed250a), so the single-path publish is safe. Envelope proto
already carries runtime_id (Phase 0 Task 6). SwiftData Agent.agentId
stays as the argument source — local rename lands in Phase 2d.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Final verification

**Files:** none (verification only)

- [ ] **Step 1: iOS clean build**

```bash
cd /Volumes/openbeta/workspace/amux/ios && xcodebuild -project AMUX.xcodeproj -scheme AMUX -destination 'generic/platform=iOS' -configuration Debug clean build CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "BUILD SUCCEEDED|BUILD FAILED|error:" | head -5
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 2: Confirm new paths are referenced**

```bash
cd /Volumes/openbeta/workspace/amux
grep -rn "MQTTTopics\.runtimeState\|MQTTTopics\.runtimeEvents\|MQTTTopics\.runtimeCommands\|MQTTTopics\.runtimeStateWildcard\|MQTTTopics\.deviceState(" ios/Packages --include='*.swift' | grep -v .pb.swift
```
Expected: hits in `SessionListViewModel.swift`, `AgentDetailViewModel.swift`, `ConnectionMonitor.swift`.

- [ ] **Step 3: Confirm legacy `agentEvents`/`agentCommands`/`agentStateWildcard` are no longer called from the three migrated files**

```bash
grep -n "MQTTTopics\.agentStateWildcard\|MQTTTopics\.agentEvents\|MQTTTopics\.agentCommands" \
    ios/Packages/AMUXCore/Sources/AMUXCore/ViewModels/SessionListViewModel.swift \
    ios/Packages/AMUXCore/Sources/AMUXCore/ViewModels/AgentDetailViewModel.swift \
    ios/Packages/AMUXCore/Sources/AMUXCore/ConnectionMonitor.swift
```
Expected: zero hits in these three files. Other files (if any) may still call the legacy methods — that's fine for Phase 2a; Phase 2d deletes them.

- [ ] **Step 4: Confirm legacy `deviceStatus` is still called by ConnectionMonitor (dual-subscribe)**

```bash
grep -n "MQTTTopics\.deviceStatus" ios/Packages/AMUXCore/Sources/AMUXCore/ConnectionMonitor.swift
```
Expected: 1 hit — Phase 2a keeps status subscription alive for LWT crash detection; Phase 3 removes it.

- [ ] **Step 5: Commit sequence review**

```bash
cd /Volumes/openbeta/workspace/amux && git log --oneline 91aea53f..HEAD
```
Expected: 4 commits — `feat(ios): add Phase 2 MQTTTopics path builders...`, `feat(ios): ConnectionMonitor dual-subscribes...`, `feat(ios): SessionListViewModel subscribes to runtime/+/state...`, `feat(ios): AgentDetailViewModel uses runtime/{id}/events and runtime/{id}/commands`.

- [ ] **Step 6: Working tree clean of our changes**

```bash
cd /Volumes/openbeta/workspace/amux && git status --porcelain
```
Expected: only pre-existing user state (`mac/Packages` unresolved conflict markers, untracked `ios/AMUXUITests/`, `scripts/run-ios.sh`).

---

## Phase 2a Complete

At this point:
- iOS subscribes to `device/{id}/runtime/+/state` wildcard and `device/{id}/runtime/{id}/events` — NOT the legacy `agent/...` counterparts.
- iOS publishes commands on `device/{id}/runtime/{id}/commands`. Daemon receives them via its Phase 1a-added runtime wildcard subscription.
- `ConnectionMonitor` dual-subscribes `device/{id}/status` + `device/{id}/state` with offline-wins merge.
- Peers, workspaces, collab, and `AcpCommand::StartAgent` paths are unchanged.
- `MQTTTopics.swift` has the new path builders alongside legacy; zero deletions.
- SwiftData `Agent` model is untouched.
- iOS clean build green.

**Next plan (Phase 2b):** iOS switches peers/workspaces/member/workspace mutations from retained topics + `/collab` to `FetchPeers`/`FetchWorkspaces` RPCs + `rpc/req` mutations. `device/{id}/notify` subscribed for cache invalidation. This unblocks daemon Phase 3 retirement of retained `peers`/`workspaces` and `/collab`.

**Phase 2c (future):** iOS adopts `RuntimeStart` RPC for the new-session flow, replacing `AcpCommand::StartAgent` via `CommandEnvelope`. Unlocks the STARTING/ACTIVE lifecycle UI from Phase 1c.

**Phase 2d (future):** SwiftData `Agent` → `Runtime` rename (destructive reset per spec default) + ViewModel / View class renames + delete legacy `MQTTTopics.swift` methods (`agentState`, `agentStateWildcard`, `agentEvents`, `agentCommands`, plus `devicePeers`, `deviceWorkspaces`, `deviceCollab` after Phase 2b retires them).

**Phase 1d (gated):** `user/{actor}/notify` subscribe + Supabase `user_inbox` reconciliation, after Supabase + EMQX JWT prereqs.
