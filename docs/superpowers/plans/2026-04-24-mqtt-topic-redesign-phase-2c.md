# Phase 2c — iOS Mutations to RPC + RuntimeStart

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Migrate iOS mutation paths off retained `device/{id}/collab` and off `agent/{new}/commands` onto the daemon's RPC handlers (`AddWorkspace`, `RemoveWorkspace`, `RuntimeStart`).

**Architecture:**
- Add three RPC helpers to `TeamclawService`: `addWorkspaceRpc(path:)`, `removeWorkspaceRpc(workspaceId:)`, `runtimeStartRpc(agentType:workspaceId:worktree:sessionId:initialPrompt:)`. They follow the existing `fetchPeers()` / `fetchWorkspaces()` pattern (publish to `device/{daemon}/rpc/req`, await response on `device/{daemon}/rpc/res`).
- Three call-site migrations: `WorkspaceManagementView` (add+remove), `MemberListContent` (add only), `NewSessionSheet` (sendAndCreate + startAgentAndWaitForState).
- **Behavior change for new-session:** `RuntimeStart` returns synchronously after spawn (accepted=true with runtime_id) — full ACP-ready lifecycle is observed asynchronously via the existing `runtime/{id}/state` subscriber. iOS persists a placeholder runtime + dismisses on accepted=true; rejection reasons are surfaced inline. This matches the user-stated invariant that new-session must not block on full daemon spawn.

**Tech Stack:** Swift 5.10, swift-protobuf, mqtt-nio. Daemon Rust handlers already in place (server.rs:1320–1804).

---

## Files

- Modify: `ios/Packages/AMUXCore/Sources/AMUXCore/TeamclawService.swift` — add `addWorkspaceRpc`, `removeWorkspaceRpc`, `runtimeStartRpc`
- Modify: `ios/Packages/AMUXUI/Sources/AMUXUI/Workspace/WorkspaceManagementView.swift` — switch addWorkspace/removeWorkspace to RPC; drop DeviceCommandEnvelope/DeviceCollabCommand usage; drop the wait-for-collab-event loop
- Modify: `ios/Packages/AMUXUI/Sources/AMUXUI/Members/MemberListContent.swift` — switch addWorkspace to RPC; drop DeviceCommandEnvelope/DeviceCollabCommand usage; drop wait-for-collab-event loop
- Modify: `ios/Packages/AMUXUI/Sources/AMUXUI/SessionList/NewSessionSheet.swift` — replace `makeStartAgentCommand` + `waitForCommandResult` with `runtimeStartRpc`; drop `Amux_DeviceCollabEvent.OneOf_Event` return type from helper

---

### Task 1: Add `addWorkspaceRpc` + `removeWorkspaceRpc` to TeamclawService

**Files:** Modify `ios/Packages/AMUXCore/Sources/AMUXCore/TeamclawService.swift`

Insert after `fetchWorkspaces()` (currently ends ~line 789, just before `private func configureRuntime`).

- [ ] **Step 1:** Add `addWorkspaceRpc` and `removeWorkspaceRpc` helpers using the same publish/await-response shape as `fetchPeers()` / `fetchWorkspaces()`.

```swift
/// Adds a workspace via daemon RPC. Returns a `(success, error)` pair —
/// daemon responds with `success=true, error=""` on accept; `success=false`
/// with a daemon-side reason on reject. Returns `(false, "timeout")` when no
/// response arrives within 10s.
public func addWorkspaceRpc(path: String) async -> (Bool, String) {
    guard let mqtt else { return (false, "mqtt not configured") }

    var add = Teamclaw_AddWorkspaceRequest()
    add.path = path

    var rpcReq = Teamclaw_RpcRequest()
    rpcReq.requestID = String(UUID().uuidString.prefix(8)).lowercased()
    rpcReq.senderDeviceID = deviceId
    rpcReq.method = .addWorkspace(add)

    let requestId = rpcReq.requestID
    let topic = MQTTTopics.deviceRpcRequest(teamID: teamId, deviceID: deviceId)
    let stream = mqtt.messages()

    guard let data = try? rpcReq.serializedData() else {
        return (false, "encode failed")
    }
    do {
        try await mqtt.publish(topic: topic, payload: data, retain: false)
    } catch {
        return (false, "publish failed: \(error.localizedDescription)")
    }

    let deadline = Date().addingTimeInterval(10)
    for await msg in stream {
        if Date() > deadline { break }
        if msg.topic == MQTTTopics.deviceRpcResponse(teamID: teamId, deviceID: deviceId),
           let response = try? Teamclaw_RpcResponse(serializedBytes: msg.payload),
           response.requestID == requestId {
            return (response.success, response.error)
        }
    }
    return (false, "timeout")
}

/// Removes a workspace via daemon RPC. Same `(success, error)` semantics as
/// `addWorkspaceRpc`.
public func removeWorkspaceRpc(workspaceId: String) async -> (Bool, String) {
    guard let mqtt else { return (false, "mqtt not configured") }

    var remove = Teamclaw_RemoveWorkspaceRequest()
    remove.workspaceID = workspaceId

    var rpcReq = Teamclaw_RpcRequest()
    rpcReq.requestID = String(UUID().uuidString.prefix(8)).lowercased()
    rpcReq.senderDeviceID = deviceId
    rpcReq.method = .removeWorkspace(remove)

    let requestId = rpcReq.requestID
    let topic = MQTTTopics.deviceRpcRequest(teamID: teamId, deviceID: deviceId)
    let stream = mqtt.messages()

    guard let data = try? rpcReq.serializedData() else {
        return (false, "encode failed")
    }
    do {
        try await mqtt.publish(topic: topic, payload: data, retain: false)
    } catch {
        return (false, "publish failed: \(error.localizedDescription)")
    }

    let deadline = Date().addingTimeInterval(10)
    for await msg in stream {
        if Date() > deadline { break }
        if msg.topic == MQTTTopics.deviceRpcResponse(teamID: teamId, deviceID: deviceId),
           let response = try? Teamclaw_RpcResponse(serializedBytes: msg.payload),
           response.requestID == requestId {
            return (response.success, response.error)
        }
    }
    return (false, "timeout")
}
```

- [ ] **Step 2:** Build the iOS app to verify the helpers compile.

Run: `cd /Volumes/openbeta/workspace/amux && xcodebuild -scheme AMUX -destination 'platform=iOS Simulator,name=iPhone 16' -workspace ios/AMUX.xcodeproj/project.xcworkspace 2>&1 | tail -50` *(or whatever the existing scheme/destination is — see prior phase commands)*. Expected: BUILD SUCCEEDED.

If the project uses `-project` (no workspace), use:
`cd /Volumes/openbeta/workspace/amux/ios && xcodebuild -scheme AMUX -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -50`

- [ ] **Step 3:** Commit.

```bash
cd /Volumes/openbeta/workspace/amux
git add ios/Packages/AMUXCore/Sources/AMUXCore/TeamclawService.swift
git commit -m "feat(ios): add addWorkspaceRpc / removeWorkspaceRpc helpers"
```

---

### Task 2: Add `runtimeStartRpc` to TeamclawService

**Files:** Modify `ios/Packages/AMUXCore/Sources/AMUXCore/TeamclawService.swift`

Insert after `removeWorkspaceRpc` (just added in Task 1).

- [ ] **Step 1:** Add `runtimeStartRpc`. The daemon's `RuntimeStart` handler (server.rs:1750–1804) returns success with `runtime_id` and `session_id` on accept; rejection includes `rejected_reason`. Match the response shape with a small return struct.

```swift
/// Spawns a runtime via daemon RPC. The daemon returns synchronously after
/// the Claude Code subprocess spawns (not after full ACP-ready) — full
/// lifecycle progress arrives via the retained `runtime/{id}/state` topic
/// that callers should already be subscribed to via SessionListViewModel.
///
/// Per spec invariant, the new-session UI must not block on full daemon
/// startup; this RPC is the synchronous accept gate, lifecycle telemetry is
/// observed asynchronously.
///
/// Returns `.accepted(runtimeID, sessionID)` or `.rejected(reason)`.
/// Times out at 15s with `.rejected("timeout")`.
public func runtimeStartRpc(
    agentType: Amux_AgentType,
    workspaceId: String,
    worktree: String,
    sessionId: String,
    initialPrompt: String
) async -> RuntimeStartOutcome {
    guard let mqtt else { return .rejected("mqtt not configured") }

    var start = Teamclaw_RuntimeStartRequest()
    start.agentType = agentType
    start.workspaceID = workspaceId
    start.worktree = worktree
    start.sessionID = sessionId
    start.initialPrompt = initialPrompt

    var rpcReq = Teamclaw_RpcRequest()
    rpcReq.requestID = String(UUID().uuidString.prefix(8)).lowercased()
    rpcReq.senderDeviceID = deviceId
    rpcReq.method = .runtimeStart(start)

    let requestId = rpcReq.requestID
    let topic = MQTTTopics.deviceRpcRequest(teamID: teamId, deviceID: deviceId)
    let stream = mqtt.messages()

    guard let data = try? rpcReq.serializedData() else {
        return .rejected("encode failed")
    }
    do {
        try await mqtt.publish(topic: topic, payload: data, retain: false)
    } catch {
        return .rejected("publish failed: \(error.localizedDescription)")
    }

    let deadline = Date().addingTimeInterval(15)
    for await msg in stream {
        if Date() > deadline { break }
        if msg.topic == MQTTTopics.deviceRpcResponse(teamID: teamId, deviceID: deviceId),
           let response = try? Teamclaw_RpcResponse(serializedBytes: msg.payload),
           response.requestID == requestId {
            if case .runtimeStartResult(let result)? = response.result {
                if result.accepted {
                    return .accepted(runtimeID: result.runtimeID, sessionID: result.sessionID)
                } else {
                    let reason = result.rejectedReason.isEmpty
                        ? (response.error.isEmpty ? "rejected" : response.error)
                        : result.rejectedReason
                    return .rejected(reason)
                }
            }
            return .rejected(response.error.isEmpty ? "no result" : response.error)
        }
    }
    return .rejected("timeout")
}

public enum RuntimeStartOutcome: Sendable {
    case accepted(runtimeID: String, sessionID: String)
    case rejected(String)
}
```

- [ ] **Step 2:** Build.

Run the same xcodebuild command from Task 1 Step 2. Expected: BUILD SUCCEEDED.

- [ ] **Step 3:** Commit.

```bash
git add ios/Packages/AMUXCore/Sources/AMUXCore/TeamclawService.swift
git commit -m "feat(ios): add runtimeStartRpc helper for synchronous spawn-accept"
```

---

### Task 3: Migrate `WorkspaceManagementView` to RPC

**Files:** Modify `ios/Packages/AMUXUI/Sources/AMUXUI/Workspace/WorkspaceManagementView.swift`

The view currently builds `Amux_DeviceCommandEnvelope`, publishes to `MQTTTopics.deviceCollab(...)`, then waits on the same topic for `Amux_DeviceCollabEvent.workspaceResult` matching the commandID. Replace with two RPC calls.

- [ ] **Step 1:** Add a TeamclawService dependency to the view. The view already takes `viewModel: SessionListViewModel`; SessionListViewModel does not directly hold a TeamclawService, so add one as a separate optional `let` initialized via the existing call site (RootTabView/SessionsTab pass `teamclawService` to SessionListViewModel.start in Phase 2b — same instance is available there).

Update the view declaration:

```swift
public struct WorkspaceManagementView: View {
    @Environment(\.modelContext) private var modelContext

    let mqtt: MQTTService
    let deviceId: String
    let peerId: String
    let viewModel: SessionListViewModel
    let teamclawService: TeamclawService

    @State private var newPath = ""
    @State private var errorMessage: String?
    @State private var isAdding = false

    private var workspaces: [Workspace] { viewModel.workspaces }

    public init(
        mqtt: MQTTService,
        deviceId: String,
        peerId: String,
        viewModel: SessionListViewModel,
        teamclawService: TeamclawService
    ) {
        self.mqtt = mqtt
        self.deviceId = deviceId
        self.peerId = peerId
        self.viewModel = viewModel
        self.teamclawService = teamclawService
    }
```

- [ ] **Step 2:** Replace `addWorkspace()` body with the RPC call. After a successful add, also call `await teamclawService.fetchWorkspaces()` and route the array through SessionListViewModel for refresh — but per the iOS pattern in TeamclawService.handleIncoming `workspaces.changed` arm, the daemon will also publish a `workspaces.changed` notify and the view model is already wired (Phase 2b placeholder); the call here is belt-and-suspenders for the immediate sender's local state.

```swift
private func addWorkspace() {
    let path = newPath.trimmingCharacters(in: .whitespaces)
    guard !path.isEmpty else { return }

    isAdding = true
    errorMessage = nil

    Task {
        let (ok, err) = await teamclawService.addWorkspaceRpc(path: path)
        await MainActor.run {
            isAdding = false
            if ok {
                newPath = ""
                errorMessage = nil
            } else {
                errorMessage = err.isEmpty ? "Add failed" : err
            }
        }
    }
}
```

- [ ] **Step 3:** Replace `removeWorkspace(_:)` body with the RPC call.

```swift
private func removeWorkspace(_ workspaceId: String) {
    Task {
        let (ok, err) = await teamclawService.removeWorkspaceRpc(workspaceId: workspaceId)
        if !ok {
            await MainActor.run {
                errorMessage = err.isEmpty ? "Remove failed" : err
            }
        }
    }
}
```

- [ ] **Step 4:** Update call sites. Find callers of `WorkspaceManagementView(mqtt:deviceId:peerId:viewModel:)` and pass `teamclawService` through. Check both AMUXUI iOS and AMUXMacUI mac targets:

```bash
rg -n "WorkspaceManagementView\(" ios/ mac/ 2>/dev/null
```

For each call site, add `teamclawService: <existing teamclawService>` to the initializer arg list. Source it from the surrounding view's environment — most likely a parent `@StateObject`/`@State` that constructs `SessionListViewModel`.

If a call site doesn't have a TeamclawService in scope, plumb the dependency through (one level up at most). Do NOT make `teamclawService` optional — it's required for the view to function.

- [ ] **Step 5:** Build.

Run iOS build. Expected: BUILD SUCCEEDED. Also verify mac build if a mac call site changed.

- [ ] **Step 6:** Commit.

```bash
git add ios/Packages/AMUXUI/Sources/AMUXUI/Workspace/WorkspaceManagementView.swift
# include any call-site files modified
git commit -m "feat(ios): WorkspaceManagementView uses AddWorkspace / RemoveWorkspace RPCs"
```

---

### Task 4: Migrate `MemberListContent` addWorkspace to RPC

**Files:** Modify `ios/Packages/AMUXUI/Sources/AMUXUI/Members/MemberListContent.swift`

Only the `addWorkspace()` method on `ActorDetailView` (~line 403) builds a DeviceCommandEnvelope. Same rewrite shape as Task 3.

- [ ] **Step 1:** Add a `TeamclawService` dependency to `ActorDetailView` (private struct ~line 94). The `MemberListContent` (public) already takes `mqtt`, `pairing`, `sessionViewModel`, `store` — extend it with `teamclawService` and pass through to `ActorDetailView`.

Updates needed:

```swift
// MemberListContent (public) — line ~7
public struct MemberListContent: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \CachedActor.displayName) private var actors: [CachedActor]
    @State private var searchText = ""

    let store: ActorStore
    let pairing: PairingManager
    let mqtt: MQTTService
    let sessionViewModel: SessionListViewModel
    let teamclawService: TeamclawService

    public init(
        store: ActorStore,
        pairing: PairingManager,
        mqtt: MQTTService,
        sessionViewModel: SessionListViewModel,
        teamclawService: TeamclawService
    ) {
        self.store = store
        self.pairing = pairing
        self.mqtt = mqtt
        self.sessionViewModel = sessionViewModel
        self.teamclawService = teamclawService
    }
```

In the body, pass `teamclawService` to `ActorDetailView(...)` (~line 47).

```swift
ActorDetailView(
    actor: a,
    pairing: pairing,
    mqtt: mqtt,
    sessionViewModel: sessionViewModel,
    store: store,
    teamclawService: teamclawService
)
```

In `ActorDetailView` (private struct ~line 94), add the field + parameter:

```swift
private struct ActorDetailView: View {
    @Query(sort: \CachedActor.displayName) private var cachedActors: [CachedActor]
    let actor: CachedActor
    let pairing: PairingManager
    let mqtt: MQTTService
    let sessionViewModel: SessionListViewModel
    let store: ActorStore
    let teamclawService: TeamclawService
    // ... existing @State stays
```

- [ ] **Step 2:** Replace the body of `addWorkspace()` (lines ~403–475).

```swift
private func addWorkspace() {
    let path = newWorkspacePath.trimmingCharacters(in: .whitespaces)
    guard !path.isEmpty else { return }

    guard !daemonDeviceID.isEmpty else {
        workspaceErrorMessage = "Missing daemon device ID."
        return
    }
    guard mqtt.connectionState == .connected else {
        workspaceErrorMessage = "MQTT is not connected."
        return
    }

    isAddingWorkspace = true
    workspaceErrorMessage = nil

    Task {
        let (ok, err) = await teamclawService.addWorkspaceRpc(path: path)
        await MainActor.run {
            isAddingWorkspace = false
            if ok {
                newWorkspacePath = ""
                workspaceErrorMessage = nil
                let workspaceStore = self.workspaceStore
                let actorId = actor.actorId
                Task { await workspaceStore?.reload(agentID: actorId) }
            } else {
                workspaceErrorMessage = err.isEmpty ? "Add failed" : err
            }
        }
    }
}
```

The `peerID` computed prop and `daemonDeviceID` checks remain useful for the gating UI text, so keep both. Remove unused references to `Amux_DeviceCommandEnvelope`, `Amux_AddWorkspace`, `Amux_DeviceCollabCommand`, and `Amux_DeviceCollabEvent` in this file — they are no longer touched.

- [ ] **Step 3:** Update call sites of `MemberListContent(store:pairing:mqtt:sessionViewModel:)`.

```bash
rg -n "MemberListContent\(" ios/ mac/ 2>/dev/null
```

Add `teamclawService:` to each.

- [ ] **Step 4:** Build (iOS, plus mac if a mac call site changed). Expected: BUILD SUCCEEDED.

- [ ] **Step 5:** Commit.

```bash
git add ios/Packages/AMUXUI/Sources/AMUXUI/Members/MemberListContent.swift
# include any call-site files modified
git commit -m "feat(ios): MemberListContent uses AddWorkspace RPC for actor workspace add"
```

---

### Task 5: Migrate `NewSessionSheet` solo-session path to RuntimeStart RPC

**Files:** Modify `ios/Packages/AMUXUI/Sources/AMUXUI/SessionList/NewSessionSheet.swift`

Two methods send `Amux_CommandEnvelope` with `AcpStartAgent`:
1. `sendAndCreate()` — solo session path (~line 486–595), waits for `agentStartResult` on collab topic
2. `startAgentAndWaitForState(initialPrompt:sessionID:)` — shared session path (~line 884–936), same wait pattern

Both helpers + `makeStartAgentCommand` + `waitForCommandResult` will be replaced by `runtimeStartRpc`.

NewSessionSheet already holds an optional `teamclawService: TeamclawService?` (used in shared-session path). Phase 2c assumes it's present whenever a runtime start is needed.

- [ ] **Step 1:** Replace the body of `sendAndCreate()` after `isSending = true` (line ~511 onward, through end of the method at ~line 595). Drop `makeStartAgentCommand`, `waitForCommandResult`, and the entire `for await msg in stream` block.

```swift
isSending = true

Task {
    guard let teamclawService else {
        await MainActor.run {
            isSending = false
            errorMessage = "TeamclawService unavailable."
        }
        return
    }

    let routeDevice = effectiveDeviceID
    guard !routeDevice.isEmpty, routeDevice != requesterDeviceID else {
        await MainActor.run {
            isSending = false
            errorMessage = "Daemon device ID is not configured."
        }
        return
    }

    await MainActor.run {
        debugStatusMessage = "starting runtime…"
        debugTransportMessage = "team=\(effectiveTeamID) route=\(routeDevice) reply=\(requesterDeviceID) (RPC)"
    }

    let outcome = await teamclawService.runtimeStartRpc(
        agentType: selectedAgentType,
        workspaceId: selectedWorkspaceRecord?.id ?? "",
        worktree: selectedWorkspaceRecord?.path ?? "",
        sessionId: "",
        initialPrompt: text
    )

    await MainActor.run {
        isSending = false
        switch outcome {
        case .accepted(let runtimeID, _):
            persistPlaceholderAgent(
                agentID: runtimeID,
                title: String(userText.prefix(50)).trimmingCharacters(in: .whitespacesAndNewlines),
                prompt: text
            )
            newSessionLogger.info(
                "new-session accepted runtimeID=\(runtimeID, privacy: .public) (lifecycle on runtime/state)"
            )
            onSessionCreated?(runtimeID)
            dismiss()
        case .rejected(let reason):
            errorMessage = reason.isEmpty ? "Agent failed to start. Check daemon logs." : reason
        }
    }
}
}
```

(Match the closing brace of the outer `private func sendAndCreate()`.)

- [ ] **Step 2:** Replace `startAgentAndWaitForState(initialPrompt:sessionID:)` (~line 884–936). Same outcome pattern, but throw `SessionCreationError.rpc(reason)` on rejection (preserves caller signature in `createSharedSession`).

```swift
private func startAgentAndWaitForState(initialPrompt: String, sessionID: String) async throws -> String {
    guard let teamclawService else {
        throw SessionCreationError.rpc("TeamclawService unavailable.")
    }

    let routeDevice = effectiveDeviceID
    guard !routeDevice.isEmpty, routeDevice != requesterDeviceID else {
        throw SessionCreationError.rpc("Daemon device ID is not configured.")
    }

    await MainActor.run {
        debugStatusMessage = "starting runtime for session \(sessionID)…"
        debugTransportMessage = "team=\(effectiveTeamID) route=\(routeDevice) reply=\(requesterDeviceID) (RPC)"
    }

    let outcome = await teamclawService.runtimeStartRpc(
        agentType: selectedAgentType,
        workspaceId: selectedWorkspaceRecord?.id ?? "",
        worktree: selectedWorkspaceRecord?.path ?? "",
        sessionId: sessionID,
        initialPrompt: initialPrompt
    )

    switch outcome {
    case .accepted(let runtimeID, _):
        return runtimeID
    case .rejected(let reason):
        throw SessionCreationError.rpc(reason.isEmpty ? "Agent failed to start. Check daemon logs." : reason)
    }
}
```

- [ ] **Step 3:** Delete `makeStartAgentCommand` (~line 749–777), `waitForCommandResult` (~line 938–980), and the `collabEventSummary` helper if it's only referenced by the deleted code.

```bash
# verify before deleting collabEventSummary
rg -n "collabEventSummary" ios/Packages/AMUXUI/Sources/AMUXUI/SessionList/NewSessionSheet.swift
```

If `collabEventSummary` has no remaining callers after Task 5 Step 1+2, delete it too.

Also remove the now-unused imports / type references: `Amux_CommandEnvelope`, `Amux_AcpCommand`, `Amux_AcpStartAgent`, `Amux_DeviceCollabEvent`. Confirm by `rg` after deletion.

- [ ] **Step 4:** Build. Expected: BUILD SUCCEEDED.

If the build fails complaining about unused or missing helpers, re-grep the file:
```bash
rg -n "makeStartAgentCommand|waitForCommandResult|collabEventSummary|Amux_CommandEnvelope|Amux_AcpStartAgent" ios/Packages/AMUXUI/Sources/AMUXUI/SessionList/NewSessionSheet.swift
```

- [ ] **Step 5:** Commit.

```bash
git add ios/Packages/AMUXUI/Sources/AMUXUI/SessionList/NewSessionSheet.swift
git commit -m "feat(ios): NewSessionSheet uses RuntimeStart RPC for solo + shared paths"
```

---

### Task 6: Final verification

- [ ] **Step 1:** Verify zero remaining `device/{id}/collab` publish call sites in iOS code (read-only inspections of `MQTTTopics.deviceCollab` are fine until Phase 2d).

```bash
rg -n "MQTTTopics.deviceCollab" ios/Packages/AMUXUI ios/Packages/AMUXCore --type swift
```

Expected output: only references inside Phase 2d-targeted code paths or zero matches if no consumer remains. If any UI code still publishes via `mqtt.publish(topic: MQTTTopics.deviceCollab(...)`, raise it — the migration is incomplete.

- [ ] **Step 2:** Verify no remaining `Amux_DeviceCommandEnvelope` or `Amux_DeviceCollabCommand` references in non-proto-generated iOS Swift files.

```bash
rg -n "Amux_DeviceCommandEnvelope|Amux_DeviceCollabCommand|Amux_AcpStartAgent" ios/Packages --type swift | rg -v "/Proto/"
```

Expected: zero matches.

- [ ] **Step 3:** Verify no remaining `agentCommands` topic publishes (the legacy `agent/{new}/commands` path).

```bash
rg -n "MQTTTopics.agentCommands" ios/Packages --type swift
```

Expected: zero matches — both `sendAndCreate` and `startAgentAndWaitForState` previously published there; both now use RPC.

- [ ] **Step 4:** Run a final iOS build.

Expected: BUILD SUCCEEDED.

- [ ] **Step 5:** Run daemon test suite to confirm no daemon-side regression (Phase 2c is iOS-only but the assertion is cheap).

```bash
cd /Volumes/openbeta/workspace/amux/daemon && cargo test 2>&1 | tail -30
```

Expected: 104 passed (or whatever the current count is — no drop).

- [ ] **Step 6:** Commit any cleanup (likely none needed).
