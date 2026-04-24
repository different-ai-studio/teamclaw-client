# Phase 2d — iOS Legacy Cleanup

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development.

**Goal:** Close out the iOS side of the MQTT topic redesign. Delete unused legacy MQTTTopics builders and the dead `device/{id}/status` subscribe in ConnectionMonitor.

**Scope decision:** The originally-planned SwiftData `Agent` → `Runtime` model rename is deferred as a separate future PR. It is a wide symbol rename (9+ files, schema version bump, destructive reset) with zero effect on the transport layer, which is already complete at Phase 5. Keeping it out keeps this phase mechanical and low-risk.

**Architecture:** Two mechanical sweeps:
1. `ConnectionMonitor` drops the legacy `/status` subscribe + the dual-merge logic (single /state source after Phase 3).
2. `MQTTTopics` drops the legacy topic builders.

**Tech Stack:** Swift 5.10, swift-protobuf, mqtt-nio.

---

### Task 1: ConnectionMonitor — single-source from /state

**File:** `ios/Packages/AMUXCore/Sources/AMUXCore/ConnectionMonitor.swift`

Currently the monitor dual-subscribes to `deviceStatus` (legacy LWT) + `deviceState` (Phase 1a new target) with offline-wins merge. After Phase 3, daemon publishes LWT on `deviceState`; `deviceStatus` is dead. Simplify.

- [ ] **Step 1:** Replace the file body with a single-source version:

```swift
import Foundation
import Observation

/// Daemon-online signal driven by the retained `device/{id}/state` topic.
/// Offline = either an explicit offline payload OR the broker-cleared (empty)
/// retained message (Phase 3 daemon LWT fires here).
@Observable
public final class ConnectionMonitor {
    public private(set) var daemonOnline: Bool = false
    public private(set) var deviceName: String = ""
    private var task: Task<Void, Never>?

    public init() {}

    public func start(mqtt: MQTTService, teamID: String = "", deviceId: String) {
        task?.cancel()
        task = Task {
            let stateTopic = MQTTTopics.deviceState(teamID: teamID, deviceID: deviceId)
            let stream = mqtt.messages()
            try? await mqtt.subscribe(stateTopic)

            for await msg in stream {
                guard msg.topic == stateTopic else { continue }
                let online: Bool
                var name: String? = nil
                if msg.payload.isEmpty {
                    online = false  // retained cleared → offline
                } else if let s = try? ProtoMQTTCoder.decode(Amux_DeviceState.self, from: msg.payload) {
                    online = s.online
                    if !s.deviceName.isEmpty { name = s.deviceName }
                } else {
                    continue  // unparseable; skip
                }

                await MainActor.run {
                    self.daemonOnline = online
                    if let name { self.deviceName = name }
                }
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }
}
```

- [ ] **Step 2:** Build iOS:
```bash
cd /Volumes/openbeta/workspace/amux/ios && xcodebuild -scheme AMUX -destination 'platform=iOS Simulator,name=iPhone 17' build 2>&1 | tail -30
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 3:** Commit:
```bash
cd /Volumes/openbeta/workspace/amux
git add ios/Packages/AMUXCore/Sources/AMUXCore/ConnectionMonitor.swift
git commit -m "refactor(ios): ConnectionMonitor single-source from device/state post-Phase-3"
```

---

### Task 2: MQTTTopics — drop legacy topic builders

**File:** `ios/Packages/AMUXCore/Sources/AMUXCore/MQTT/MQTTTopics.swift`

Delete the static methods whose topics the daemon no longer publishes or subscribes to (Phase 3 retired them on the daemon side; Phase 2a+2b+2c migrated all iOS call sites to the new paths).

- [ ] **Step 1:** Delete from MQTTTopics:
- `deviceStatus(teamID:deviceID:)`
- `devicePeers(teamID:deviceID:)`
- `deviceWorkspaces(teamID:deviceID:)`
- `deviceCollab(teamID:deviceID:)`
- `agentState(teamID:deviceID:agentID:)`
- `agentStateWildcard(teamID:deviceID:)`
- `agentStatePrefix(teamID:deviceID:)`
- `agentEvents(teamID:deviceID:agentID:)`
- `agentCommands(teamID:deviceID:agentID:)`

**KEEP:** `normalizedTeamID`, `deviceBase`, `teamclawBase`, `deviceRpcRequest`, `deviceRpcResponse`, `deviceNotify`, `sessionLive`, `deviceState`, `runtimeState`, `runtimeStateWildcard`, `runtimeStatePrefix`, `runtimeEvents`, `runtimeCommands`, `runtimeCommandsWildcard`, `userNotify`.

- [ ] **Step 2:** Verify zero remaining live call sites of the deleted methods:
```bash
/usr/bin/grep -rEn "MQTTTopics\.(deviceStatus|devicePeers|deviceWorkspaces|deviceCollab|agentState|agentStateWildcard|agentStatePrefix|agentEvents|agentCommands)" ios/Packages ios/AMUXApp mac/Packages --include="*.swift" 2>/dev/null
```
Expected: zero matches.

- [ ] **Step 3:** Build iOS:
```bash
cd /Volumes/openbeta/workspace/amux/ios && xcodebuild -scheme AMUX -destination 'platform=iOS Simulator,name=iPhone 17' build 2>&1 | tail -30
```
Expected: BUILD SUCCEEDED.

If a build fails with "type 'MQTTTopics' has no member …", audit and fix the call site (should be zero such sites after Phase 2a-2c+Phase 5 + Task 1 of this phase).

- [ ] **Step 4:** Commit:
```bash
cd /Volumes/openbeta/workspace/amux
git add ios/Packages/AMUXCore/Sources/AMUXCore/MQTT/MQTTTopics.swift
git commit -m "refactor(ios): delete legacy MQTTTopics builders (deviceStatus/Peers/Workspaces/Collab, agent/*)"
```

---

### Task 3: Final cross-cutting verification

- [ ] **Step 1:** Run the daemon test suite one final time:
```bash
cd /Volumes/openbeta/workspace/amux
export SUPABASE_URL="https://srhaytajyfrniuvnkfpd.supabase.co/rest/v1/"
export SUPABASE_ANON_KEY="sb_publishable_CJavqYCusEBD7cIebhH5tQ_K_I9AXpE"
cd daemon && cargo test 2>&1 | tail -10
```
Expected: 98 pass.

- [ ] **Step 2:** Run iOS build:
```bash
cd /Volumes/openbeta/workspace/amux/ios && xcodebuild -scheme AMUX -destination 'platform=iOS Simulator,name=iPhone 17' build 2>&1 | tail -10
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 3:** Cross-cutting grep — confirm the entire migration is clean:
```bash
# daemon
/usr/bin/grep -rEn "topics\.(status|peers|workspaces|collab|agent_state|agent_events|agent_commands|all_agent_commands)\(|publish_(peer_list|workspace_list|device_collab_event|device_collab_event_to|agent_state|agent_event)|clear_agent_state|AgentManager|AgentHandle|crate::agent::|amux::CommandEnvelope|amux::DeviceCommandEnvelope|amux::DeviceCollabEvent|amux::DeviceCollabCommand|amux::LegacyAgentStartResult|amux::PeerJoined|amux::PeerLeft|amux::PeerKicked|amux::MemberListChanged|amux::AuthResult|amux::InviteCreated|amux::WorkspaceResult|amux::InviteMember|teamclaw::NotifyEnvelope" daemon/src

# iOS
/usr/bin/grep -rEn "MQTTTopics\.(deviceStatus|devicePeers|deviceWorkspaces|deviceCollab|agentState|agentStateWildcard|agentStatePrefix|agentEvents|agentCommands)|Amux_(CommandEnvelope|DeviceCommandEnvelope|DeviceCollabEvent|DeviceCollabCommand|LegacyAgentStartResult|PeerJoined|PeerLeft|PeerKicked|MemberListChanged|AuthResult|InviteCreated|WorkspaceResult|PeerDisconnect|InviteMember)|Teamclaw_NotifyEnvelope" ios/Packages --include="*.swift"
```

Expected: zero matches on both sides.
