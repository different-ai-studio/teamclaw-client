# Teamclaw MQTT Rearchitecture Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Teamclaw's stateful MQTT model with a realtime-only routing layer built on device RPC, device notify, and per-session live streams.

**Architecture:** Keep truth in Supabase and explicit RPC reads, while collapsing Teamclaw MQTT onto `device/{device}/rpc/{req|res}`, `device/{device}/notify`, and `session/{session}/live`. iOS/mac app clients subscribe only to foreground sessions; the daemon maintains a background session subscription set derived from session membership truth. The rollout is staged: add new channels first, dual-publish while clients migrate, then delete old retained session state and team-wide indexes.

**Tech Stack:** Rust (rumqttc, tokio, prost), Swift (CocoaMQTT, SwiftProtobuf, SwiftData), Supabase, Protobuf v3

**Spec:** `docs/superpowers/specs/2026-04-23-teamclaw-mqtt-rearchitecture-design.md`

---

## File Structure

### Modify

- `proto/teamclaw.proto`
- `daemon/src/teamclaw/topics.rs`
- `daemon/src/teamclaw/rpc.rs`
- `daemon/src/teamclaw/session_manager.rs`
- `daemon/src/mqtt/subscriber.rs`
- `daemon/src/daemon/server.rs`
- `ios/Packages/AMUXCore/Sources/AMUXCore/MQTT/MQTTTopics.swift`
- `ios/Packages/AMUXCore/Sources/AMUXCore/TeamclawService.swift`
- `ios/Packages/AMUXCore/Sources/AMUXCore/MQTT/MQTTService.swift`

### Create

- `daemon/src/teamclaw/notify.rs`
- `daemon/src/teamclaw/live.rs`
- `ios/Packages/AMUXCore/Tests/AMUXCoreTests/MQTTTopicsTests.swift`
- `ios/Packages/AMUXCore/Tests/AMUXCoreTests/TeamclawServiceSubscriptionTests.swift`
- `daemon/tests/teamclaw_mqtt_rearchitecture.rs`

### Verify

- `cd daemon && cargo test --test teamclaw_mqtt_rearchitecture`
- `cd daemon && cargo test session_manager`
- `cd ios/Packages/AMUXCore && swift test --filter MQTTTopicsTests`
- `cd ios/Packages/AMUXCore && swift test --filter TeamclawServiceSubscriptionTests`

---

### Task 1: Add the New MQTT Contract Without Breaking Existing Clients

**Files:**
- Modify: `proto/teamclaw.proto`
- Modify: `daemon/src/teamclaw/topics.rs`
- Modify: `ios/Packages/AMUXCore/Sources/AMUXCore/MQTT/MQTTTopics.swift`
- Test: `daemon/tests/teamclaw_mqtt_rearchitecture.rs`
- Test: `ios/Packages/AMUXCore/Tests/AMUXCoreTests/MQTTTopicsTests.swift`

- [ ] **Step 1: Write the failing Rust topic-contract test**

```rust
use amux::teamclaw::TeamclawTopics;

#[test]
fn builds_new_device_and_live_topics() {
    let topics = TeamclawTopics::new("team1", "dev-a");

    assert_eq!(topics.device_rpc_req(), "amux/team1/device/dev-a/rpc/req");
    assert_eq!(topics.device_rpc_res(), "amux/team1/device/dev-a/rpc/res");
    assert_eq!(topics.device_notify(), "amux/team1/device/dev-a/notify");
    assert_eq!(topics.session_live("sess-1"), "amux/team1/session/sess-1/live");
}
```

- [ ] **Step 2: Run the Rust test and confirm it fails**

Run: `cd daemon && cargo test --test teamclaw_mqtt_rearchitecture -- --nocapture`

Expected: compile failure because `device_rpc_req`, `device_rpc_res`, `device_notify`, and `session_live` do not exist yet.

- [ ] **Step 3: Extend the protobuf schema with the new envelope types**

```protobuf
message LiveEventEnvelope {
  string event_id = 1;
  string event_type = 2;
  string session_id = 3;
  string actor_id = 4;
  int64 sent_at = 5;
  bytes body = 6;
}

message NotifyEnvelope {
  string event_id = 1;
  string event_type = 2;
  string target_device_id = 3;
  string session_id = 4;
  int64 sent_at = 5;
  string reason = 6;
}
```

- [ ] **Step 4: Add the topic builders on the Rust side**

```rust
impl TeamclawTopics {
    pub fn device_rpc_req(&self) -> String {
        format!("{}/device/{}/rpc/req", self.base(), self.device_id)
    }

    pub fn device_rpc_res(&self) -> String {
        format!("{}/device/{}/rpc/res", self.base(), self.device_id)
    }

    pub fn device_notify(&self) -> String {
        format!("{}/device/{}/notify", self.base(), self.device_id)
    }

    pub fn session_live(&self, session_id: &str) -> String {
        format!("{}/session/{}/live", self.base(), session_id)
    }
}
```

- [ ] **Step 5: Add the topic builders on the Swift side**

```swift
public static func deviceRpcRequest(teamID: String, deviceID: String) -> String {
    "\(deviceBase(teamID: teamID, deviceID: deviceID))/rpc/req"
}

public static func deviceRpcResponse(teamID: String, deviceID: String) -> String {
    "\(deviceBase(teamID: teamID, deviceID: deviceID))/rpc/res"
}

public static func deviceNotify(teamID: String, deviceID: String) -> String {
    "\(deviceBase(teamID: teamID, deviceID: deviceID))/notify"
}

public static func sessionLive(teamID: String, sessionID: String) -> String {
    "\(teamclawBase(teamID: teamID))/session/\(sessionID)/live"
}
```

- [ ] **Step 6: Add a matching Swift unit test**

```swift
import XCTest
@testable import AMUXCore

final class MQTTTopicsTests: XCTestCase {
    func testTeamclawRearchitectureTopics() {
        XCTAssertEqual(MQTTTopics.deviceRpcRequest(teamID: "team1", deviceID: "dev-a"),
                       "amux/team1/device/dev-a/rpc/req")
        XCTAssertEqual(MQTTTopics.deviceRpcResponse(teamID: "team1", deviceID: "dev-a"),
                       "amux/team1/device/dev-a/rpc/res")
        XCTAssertEqual(MQTTTopics.deviceNotify(teamID: "team1", deviceID: "dev-a"),
                       "amux/team1/device/dev-a/notify")
        XCTAssertEqual(MQTTTopics.sessionLive(teamID: "team1", sessionID: "sess-1"),
                       "amux/team1/session/sess-1/live")
    }
}
```

- [ ] **Step 7: Run the focused tests and confirm they pass**

Run: `cd daemon && cargo test --test teamclaw_mqtt_rearchitecture`

Expected: PASS

Run: `cd ios/Packages/AMUXCore && swift test --filter MQTTTopicsTests`

Expected: PASS

- [ ] **Step 8: Commit**

```bash
git add proto/teamclaw.proto \
  daemon/src/teamclaw/topics.rs \
  ios/Packages/AMUXCore/Sources/AMUXCore/MQTT/MQTTTopics.swift \
  daemon/tests/teamclaw_mqtt_rearchitecture.rs \
  ios/Packages/AMUXCore/Tests/AMUXCoreTests/MQTTTopicsTests.swift
git commit -m "feat(teamclaw): add new MQTT routing contract"
```

### Task 2: Add Device Notify and Session Live Publishing on the Daemon

**Files:**
- Create: `daemon/src/teamclaw/notify.rs`
- Create: `daemon/src/teamclaw/live.rs`
- Modify: `daemon/src/teamclaw/session_manager.rs`
- Modify: `daemon/src/mqtt/subscriber.rs`
- Modify: `daemon/src/daemon/server.rs`
- Test: `daemon/tests/teamclaw_mqtt_rearchitecture.rs`

- [ ] **Step 1: Write the failing daemon routing test**

```rust
#[tokio::test]
async fn parse_session_live_and_device_notify_topics() {
    let live = rumqttc::Publish::new("amux/team1/session/sess-1/live", rumqttc::QoS::AtLeastOnce, vec![1, 2, 3]);
    let notify = rumqttc::Publish::new("amux/team1/device/dev-a/notify", rumqttc::QoS::AtLeastOnce, vec![4, 5, 6]);

    assert!(matches!(
        amux::mqtt::subscriber::parse_incoming(&live),
        Some(amux::mqtt::subscriber::IncomingMessage::TeamclawSessionLive { .. })
    ));
    assert!(matches!(
        amux::mqtt::subscriber::parse_incoming(&notify),
        Some(amux::mqtt::subscriber::IncomingMessage::TeamclawNotify { .. })
    ));
}
```

- [ ] **Step 2: Run the test and confirm it fails**

Run: `cd daemon && cargo test --test teamclaw_mqtt_rearchitecture -- --nocapture`

Expected: compile failure because `TeamclawSessionLive` and `TeamclawNotify` enum variants do not exist.

- [ ] **Step 3: Add a small publisher helper for notify and live events**

```rust
pub struct NotifyPublisher {
    client: AsyncClient,
    topics: TeamclawTopics,
}

impl NotifyPublisher {
    pub async fn publish_membership_refresh(&self, target_device_id: &str, session_id: &str) -> crate::error::Result<()> {
        let payload = NotifyEnvelope {
            event_id: Uuid::new_v4().to_string(),
            event_type: "membership.refresh".to_string(),
            target_device_id: target_device_id.to_string(),
            session_id: session_id.to_string(),
            sent_at: Utc::now().timestamp(),
            reason: "participant_added".to_string(),
        }.encode_to_vec();

        let topic = TeamclawTopics::new(&self.topics.team_id, target_device_id).device_notify();
        self.client.publish(topic, QoS::AtLeastOnce, false, payload).await?;
        Ok(())
    }
}
```

- [ ] **Step 4: Publish live events whenever session messages/tasks/presence are emitted**

```rust
let live = LiveEventEnvelope {
    event_id: Uuid::new_v4().to_string(),
    event_type: "message.created".to_string(),
    session_id: session_id.to_string(),
    actor_id: agent_actor_id.to_string(),
    sent_at: Utc::now().timestamp(),
    body: envelope.encode_to_vec(),
};

self.client
    .publish(self.topics.session_live(session_id), QoS::AtLeastOnce, false, live.encode_to_vec())
    .await?;
```

- [ ] **Step 5: Teach the MQTT subscriber to parse the new topics**

```rust
pub enum IncomingMessage {
    TeamclawNotify { payload: Vec<u8> },
    TeamclawSessionLive { session_id: String, payload: Vec<u8> },
    // existing variants...
}

if parts.len() == 5 && parts[2] == "session" && parts[4] == "live" {
    return Some(IncomingMessage::TeamclawSessionLive {
        session_id: parts[3].to_string(),
        payload: publish.payload.to_vec(),
    });
}

if parts.len() == 5 && parts[2] == "device" && parts[4] == "notify" {
    return Some(IncomingMessage::TeamclawNotify {
        payload: publish.payload.to_vec(),
    });
}
```

- [ ] **Step 6: Send targeted notify events from participant-add flows**

```rust
for target_device_id in affected_device_ids {
    self.notify_publisher
        .publish_membership_refresh(&target_device_id, &r.session_id)
        .await?;
}
```

- [ ] **Step 7: Run the daemon tests and confirm they pass**

Run: `cd daemon && cargo test --test teamclaw_mqtt_rearchitecture`

Expected: PASS

- [ ] **Step 8: Commit**

```bash
git add daemon/src/teamclaw/notify.rs \
  daemon/src/teamclaw/live.rs \
  daemon/src/teamclaw/session_manager.rs \
  daemon/src/mqtt/subscriber.rs \
  daemon/src/daemon/server.rs \
  daemon/tests/teamclaw_mqtt_rearchitecture.rs
git commit -m "feat(teamclaw): add notify and live event channels"
```

### Task 3: Move App Clients to Foreground-Only Session Live Subscriptions

**Files:**
- Modify: `ios/Packages/AMUXCore/Sources/AMUXCore/TeamclawService.swift`
- Modify: `ios/Packages/AMUXCore/Sources/AMUXCore/MQTT/MQTTService.swift`
- Test: `ios/Packages/AMUXCore/Tests/AMUXCoreTests/TeamclawServiceSubscriptionTests.swift`

- [ ] **Step 1: Write the failing Swift subscription-lifecycle test**

```swift
import XCTest
@testable import AMUXCore

final class TeamclawServiceSubscriptionTests: XCTestCase {
    func testForegroundSessionSetOnlyTracksOpenSessions() async {
        let service = TeamclawService()

        await service.markSessionVisible("sess-1")
        XCTAssertEqual(await service.foregroundSessionIDs(), ["sess-1"])

        await service.markSessionHidden("sess-1")
        XCTAssertEqual(await service.foregroundSessionIDs(), [])
    }
}
```

- [ ] **Step 2: Run the test and confirm it fails**

Run: `cd ios/Packages/AMUXCore && swift test --filter TeamclawServiceSubscriptionTests`

Expected: compile failure because `markSessionVisible`, `markSessionHidden`, and `foregroundSessionIDs` do not exist.

- [ ] **Step 3: Add explicit foreground session lifecycle APIs**

```swift
private var foregroundSessions: Set<String> = []

public func markSessionVisible(_ sessionID: String) async {
    guard foregroundSessions.insert(sessionID).inserted else { return }
    guard let mqtt else { return }
    try? await mqtt.subscribe(MQTTTopics.sessionLive(teamID: teamId, sessionID: sessionID))
}

public func markSessionHidden(_ sessionID: String) async {
    guard foregroundSessions.remove(sessionID) != nil else { return }
    guard let mqtt else { return }
    try? await mqtt.unsubscribe(MQTTTopics.sessionLive(teamID: teamId, sessionID: sessionID))
}

public func foregroundSessionIDs() async -> [String] {
    foregroundSessions.sorted()
}
```

- [ ] **Step 4: Stop auto-subscribing to every seen session**

```swift
private func handleIncoming(_ incoming: MQTTIncoming, modelContext: ModelContext) async {
    let topic = incoming.topic

    if topic == MQTTTopics.sessionLive(teamID: teamId, sessionID: currentSessionID) {
        await handleLiveEvent(incoming.payload, modelContext: modelContext)
        return
    }

    // remove subscribeToSession(envelope.session.sessionID) and
    // remove any implicit "invite means subscribe forever" behavior
}
```

- [ ] **Step 5: Add `unsubscribe` to `MQTTService` if the wrapper does not expose it cleanly**

```swift
public func unsubscribe(_ topic: String) async throws {
    try await withCheckedThrowingContinuation { continuation in
        mqtt?.unsubscribe(topic)
        continuation.resume()
    }
}
```

- [ ] **Step 6: Update the live-message decode path to use the new envelope**

```swift
private func handleLiveEvent(_ payload: Data, modelContext: ModelContext) async {
    guard let event = try? Teamclaw_LiveEventEnvelope(serializedBytes: payload) else { return }

    switch event.eventType {
    case "message.created":
        guard let envelope = try? Teamclaw_SessionMessageEnvelope(serializedBytes: event.body) else { return }
        if envelope.hasMessage { syncMessage(envelope.message, modelContext: modelContext) }
    case "task.updated", "task.created":
        guard let task = try? Teamclaw_TaskEvent(serializedBytes: event.body) else { return }
        syncTaskEvent(task, modelContext: modelContext)
    default:
        break
    }
}
```

- [ ] **Step 7: Run the focused Swift tests**

Run: `cd ios/Packages/AMUXCore && swift test --filter TeamclawServiceSubscriptionTests`

Expected: PASS

- [ ] **Step 8: Commit**

```bash
git add ios/Packages/AMUXCore/Sources/AMUXCore/TeamclawService.swift \
  ios/Packages/AMUXCore/Sources/AMUXCore/MQTT/MQTTService.swift \
  ios/Packages/AMUXCore/Tests/AMUXCoreTests/TeamclawServiceSubscriptionTests.swift
git commit -m "feat(ios): limit Teamclaw live subscriptions to foreground sessions"
```

### Task 4: Make the Daemon Maintain Its Session Live Set From Membership Truth

**Files:**
- Modify: `daemon/src/teamclaw/session_manager.rs`
- Modify: `daemon/src/teamclaw/rpc.rs`
- Modify: `daemon/src/daemon/server.rs`
- Test: `daemon/tests/teamclaw_mqtt_rearchitecture.rs`

- [ ] **Step 1: Write the failing daemon membership-sync test**

```rust
#[tokio::test]
async fn membership_refresh_updates_live_subscriptions() {
    let mut manager = test_session_manager();

    manager.apply_membership_sessions(vec!["sess-1".to_string(), "sess-2".to_string()]).await.unwrap();
    assert_eq!(manager.subscribed_live_sessions(), vec!["sess-1".to_string(), "sess-2".to_string()]);

    manager.apply_membership_sessions(vec!["sess-2".to_string()]).await.unwrap();
    assert_eq!(manager.subscribed_live_sessions(), vec!["sess-2".to_string()]);
}
```

- [ ] **Step 2: Run the test and confirm it fails**

Run: `cd daemon && cargo test --test teamclaw_mqtt_rearchitecture -- --nocapture`

Expected: compile failure because `apply_membership_sessions` and `subscribed_live_sessions` do not exist.

- [ ] **Step 3: Add an explicit daemon session-subscription set**

```rust
pub struct SessionManager {
    // existing fields...
    subscribed_live_sessions: BTreeSet<String>,
}

pub async fn apply_membership_sessions(&mut self, session_ids: Vec<String>) -> crate::error::Result<()> {
    let desired: BTreeSet<String> = session_ids.into_iter().collect();

    for session_id in desired.difference(&self.subscribed_live_sessions) {
        self.client.subscribe(self.topics.session_live(session_id), QoS::AtLeastOnce).await?;
    }

    for session_id in self.subscribed_live_sessions.difference(&desired) {
        self.client.unsubscribe(self.topics.session_live(session_id)).await?;
    }

    self.subscribed_live_sessions = desired;
    Ok(())
}
```

- [ ] **Step 4: Trigger membership refresh from targeted notify and reconnect**

```rust
pub async fn handle_notify(&mut self, payload: &[u8]) -> crate::error::Result<()> {
    let notify = NotifyEnvelope::decode(payload)?;
    if notify.event_type == "membership.refresh" {
        let session_ids = self.membership_repository.active_session_ids_for_device(&self.device_id).await?;
        self.apply_membership_sessions(session_ids).await?;
    }
    Ok(())
}
```

- [ ] **Step 5: Add an explicit catch-up RPC hook after subscription refresh**

```rust
for session_id in &self.subscribed_live_sessions {
    self.request_recent_session_events(session_id, self.last_seen_cursor(session_id)).await?;
}
```

- [ ] **Step 6: Run the daemon tests**

Run: `cd daemon && cargo test --test teamclaw_mqtt_rearchitecture`

Expected: PASS

- [ ] **Step 7: Commit**

```bash
git add daemon/src/teamclaw/session_manager.rs \
  daemon/src/teamclaw/rpc.rs \
  daemon/src/daemon/server.rs \
  daemon/tests/teamclaw_mqtt_rearchitecture.rs
git commit -m "feat(daemon): sync live subscriptions from membership state"
```

### Task 5: Remove Teamclaw Retained Session State and Old Session Fan-Out

**Files:**
- Modify: `daemon/src/teamclaw/session_manager.rs`
- Modify: `daemon/src/teamclaw/topics.rs`
- Modify: `ios/Packages/AMUXCore/Sources/AMUXCore/TeamclawService.swift`
- Test: `daemon/tests/teamclaw_mqtt_rearchitecture.rs`
- Test: `ios/Packages/AMUXCore/Tests/AMUXCoreTests/TeamclawServiceSubscriptionTests.swift`

- [ ] **Step 1: Write the failing regression test for "no retained session state"**

```rust
#[tokio::test]
async fn session_realtime_publish_is_not_retained() {
    let publish = build_live_publish_for_test("sess-1");
    assert!(!publish.retain);
}
```

- [ ] **Step 2: Run the test and confirm it fails**

Run: `cd daemon && cargo test teamclaw_mqtt_rearchitecture -- --nocapture`

Expected: failure because the helper still publishes retained session state or still routes through legacy retained publishers.

- [ ] **Step 3: Delete team-wide retained session index publication**

```rust
// remove these calls from create/join/add/remove participant flows:
// self.publish_session_index().await?;
// self.publish_session_meta(&session_id).await?;

// keep explicit persistence, but stop mirroring session state to retained MQTT topics
```

- [ ] **Step 4: Delete actor-scoped retained session metadata and old auto-subscribe paths**

```rust
// remove:
// self.topics.actor_session_meta(...)
// self.topics.actor_session_meta_wildcard(...)
// self.topics.sessions()
```

```swift
// remove:
// MQTTTopics.teamSessions(...)
// MQTTTopics.actorSessionMetaWildcard(...)
// subscribeToSession(...)
```

- [ ] **Step 5: Replace old session fan-out with explicit refresh paths**

```swift
if notify.eventType == "membership.refresh" {
    await refreshMembershipAndMessages(for: notify.sessionID)
}
```

- [ ] **Step 6: Run the high-signal verification set**

Run: `cd daemon && cargo test session_manager`

Expected: PASS

Run: `cd daemon && cargo test --test teamclaw_mqtt_rearchitecture`

Expected: PASS

Run: `cd ios/Packages/AMUXCore && swift test --filter TeamclawServiceSubscriptionTests`

Expected: PASS

- [ ] **Step 7: Commit**

```bash
git add daemon/src/teamclaw/session_manager.rs \
  daemon/src/teamclaw/topics.rs \
  ios/Packages/AMUXCore/Sources/AMUXCore/TeamclawService.swift \
  daemon/tests/teamclaw_mqtt_rearchitecture.rs \
  ios/Packages/AMUXCore/Tests/AMUXCoreTests/TeamclawServiceSubscriptionTests.swift
git commit -m "refactor(teamclaw): remove retained session MQTT state"
```

### Task 6: Final Verification and Compatibility Sweep

**Files:**
- Modify: `docs/superpowers/specs/2026-04-23-teamclaw-mqtt-rearchitecture-design.md`
- Modify: `docs/superpowers/plans/2026-04-23-teamclaw-mqtt-rearchitecture.md`

- [ ] **Step 1: Verify the daemon can still parse mixed old/new traffic during rollout**

```rust
#[tokio::test]
async fn mixed_legacy_and_live_topics_parse_during_rollout() {
    let legacy = rumqttc::Publish::new("amux/team1/session/sess-1/messages", rumqttc::QoS::AtLeastOnce, vec![]);
    let live = rumqttc::Publish::new("amux/team1/session/sess-1/live", rumqttc::QoS::AtLeastOnce, vec![]);

    assert!(parse_incoming(&legacy).is_some());
    assert!(parse_incoming(&live).is_some());
}
```

- [ ] **Step 2: Run the full verification set**

Run: `cd daemon && cargo test`

Expected: PASS

Run: `cd ios/Packages/AMUXCore && swift test`

Expected: PASS

- [ ] **Step 3: Update the spec and plan if implementation realities changed names or sequencing**

```md
- if `membership.refresh` was renamed, update the spec's notify examples
- if the catch-up RPC uses timestamps instead of cursors, update both documents
```

- [ ] **Step 4: Commit**

```bash
git add docs/superpowers/specs/2026-04-23-teamclaw-mqtt-rearchitecture-design.md \
  docs/superpowers/plans/2026-04-23-teamclaw-mqtt-rearchitecture.md
git commit -m "docs(teamclaw): finalize MQTT rearchitecture rollout notes"
```

---

## Self-Review

- Spec coverage: topic contract, notify/live/rpc boundaries, app-vs-daemon subscription split, reconnect flow, catch-up flow, and migration/deletion of retained state each map to at least one task.
- Placeholder scan: no `TBD`/`TODO` markers remain in the plan; each task names exact files and verification commands.
- Type consistency: the plan consistently uses `NotifyEnvelope`, `LiveEventEnvelope`, `membership.refresh`, `deviceNotify`, and `sessionLive`.
