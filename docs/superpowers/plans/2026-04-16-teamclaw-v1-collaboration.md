# Teamclaw V1 Collaboration Layer — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a collaboration layer to AMUX so a small team can put humans, personal agents, and role agents into shared sessions — while preserving private control channels.

**Architecture:** New `proto/teamclaw.proto` defines all collaboration types. Daemon gets a `teamclaw/` module with stores, MQTT topic handlers, and session lifecycle. iOS gets new SwiftData models, teamclaw MQTT subscriptions, and collab session views. All communication is MQTT-only (no HTTP).

**Tech Stack:** Rust (prost, rumqttc, tokio, serde, toml), Swift (SwiftUI, SwiftData, CocoaMQTT, SwiftProtobuf), Protobuf v3

**Spec:** `docs/superpowers/specs/2026-04-16-teamclaw-v1-collaboration-design.md`

---

## File Structure

### New Files

```
proto/teamclaw.proto                                    # Teamclaw protobuf schema

daemon/src/teamclaw/mod.rs                              # Module exports
daemon/src/teamclaw/topics.rs                           # MQTT topic builder for teamclaw namespace
daemon/src/teamclaw/rpc.rs                              # MQTT request/reply handler
daemon/src/teamclaw/session_store.rs                    # Collab/control session metadata store
daemon/src/teamclaw/message_store.rs                    # Message persistence per session
daemon/src/teamclaw/work_item_store.rs                  # WorkItem, Claim, Submission store
daemon/src/teamclaw/session_manager.rs                  # Session lifecycle (create, join, fork, agent routing)
daemon/src/teamclaw/team_host.rs                        # Team host duties (session index, member directory)

ios/Packages/AMUXCore/Sources/AMUXCore/Proto/teamclaw.pb.swift  # Generated Swift proto
ios/Packages/AMUXCore/Sources/AMUXCore/Models/CollabSession.swift  # SwiftData model
ios/Packages/AMUXCore/Sources/AMUXCore/Models/SessionMessage.swift # SwiftData model
ios/Packages/AMUXCore/Sources/AMUXCore/Models/WorkItem.swift       # SwiftData model
ios/Packages/AMUXCore/Sources/AMUXCore/TeamclawService.swift       # Teamclaw MQTT subscriptions + RPC client

ios/Packages/AMUXUI/Sources/AMUXUI/Collab/CollabSessionView.swift       # Collab session chat view
ios/Packages/AMUXUI/Sources/AMUXUI/Collab/CollabSessionViewModel.swift  # ViewModel for collab
ios/Packages/AMUXUI/Sources/AMUXUI/Collab/WorkItemListView.swift        # Work items in collab session
ios/Packages/AMUXUI/Sources/AMUXUI/Collab/InviteSheet.swift             # Invite participants
ios/Packages/AMUXUI/Sources/AMUXUI/Collab/NewCollabSheet.swift          # Create collab session
```

### Modified Files

```
daemon/build.rs                                         # Add teamclaw.proto to compilation
daemon/src/proto.rs                                     # Add teamclaw module
daemon/src/main.rs                                      # Wire teamclaw into daemon startup
daemon/src/daemon/server.rs                             # Integrate teamclaw session manager into main loop
daemon/src/mqtt/client.rs                               # Subscribe to teamclaw topics
daemon/src/mqtt/subscriber.rs                           # Parse teamclaw incoming messages

scripts/proto-gen-swift.sh                              # Add teamclaw.proto generation

ios/Packages/AMUXCore/Sources/AMUXCore/Models/Agent.swift  # Add sessionType field
ios/AMUXApp/AMUXApp.swift                               # Register new SwiftData models
ios/AMUXApp/ContentView.swift                           # Initialize TeamclawService
ios/Packages/AMUXUI/Sources/AMUXUI/SessionList/SessionListView.swift       # Show control + collab sessions
ios/Packages/AMUXUI/Sources/AMUXUI/SessionList/SessionListViewModel.swift  # Subscribe to teamclaw session index
ios/Packages/AMUXUI/Sources/AMUXUI/AgentDetail/AgentDetailView.swift       # Add "Fork to collab" action
```

---

## Task 1: Protobuf Schema

**Files:**
- Create: `proto/teamclaw.proto`
- Modify: `daemon/build.rs`
- Modify: `daemon/src/proto.rs`
- Modify: `scripts/proto-gen-swift.sh`

- [ ] **Step 1: Create `proto/teamclaw.proto`**

```protobuf
syntax = "proto3";
package teamclaw;

// --- Enums ---

enum SessionType {
  SESSION_TYPE_UNKNOWN = 0;
  CONTROL = 1;
  COLLAB = 2;
}

enum ActorType {
  ACTOR_TYPE_UNKNOWN = 0;
  HUMAN = 1;
  PERSONAL_AGENT = 2;
  ROLE_AGENT = 3;
}

enum MessageKind {
  MESSAGE_KIND_UNKNOWN = 0;
  TEXT = 1;
  SYSTEM = 2;
  WORK_EVENT = 3;
}

enum WorkItemStatus {
  WORK_ITEM_STATUS_UNKNOWN = 0;
  OPEN = 1;
  IN_PROGRESS = 2;
  DONE = 3;
}

// --- Core Types ---

message Actor {
  string actor_id = 1;
  ActorType actor_type = 2;
  string display_name = 3;
  string owner_member_id = 4;   // for personal_agent: the owning human's member_id
  string host_device_id = 5;    // which amuxd runs this actor (for agents)
}

message SessionInfo {
  string session_id = 1;
  SessionType session_type = 2;
  string team_id = 3;
  string title = 4;
  string host_device_id = 5;
  string created_by = 6;        // actor_id
  int64 created_at = 7;
  repeated Participant participants = 8;
  string summary = 9;           // handoff or session summary
}

message Participant {
  string actor_id = 1;
  ActorType actor_type = 2;
  string display_name = 3;
  int64 joined_at = 4;
}

message SessionIndexEntry {
  string session_id = 1;
  SessionType session_type = 2;
  string title = 3;
  string host_device_id = 4;
  int64 created_at = 5;
  int32 participant_count = 6;
  string last_message_preview = 7;
  int64 last_message_at = 8;
}

message SessionIndex {
  repeated SessionIndexEntry sessions = 1;
}

message Message {
  string message_id = 1;
  string session_id = 2;
  string sender_actor_id = 3;
  MessageKind kind = 4;
  string content = 5;
  int64 created_at = 6;
  string reply_to_message_id = 7;
  repeated string mentions = 8;
}

message WorkItem {
  string work_item_id = 1;
  string session_id = 2;
  string title = 3;
  string description = 4;
  WorkItemStatus status = 5;
  string parent_id = 6;
  string created_by = 7;
  int64 created_at = 8;
  repeated Claim claims = 9;
  repeated Submission submissions = 10;
}

message Claim {
  string claim_id = 1;
  string work_item_id = 2;
  string actor_id = 3;
  int64 claimed_at = 4;
}

message Submission {
  string submission_id = 1;
  string work_item_id = 2;
  string actor_id = 3;
  string content = 4;
  int64 submitted_at = 5;
}

message Invite {
  string invite_id = 1;
  string session_id = 2;
  string team_id = 3;
  string host_device_id = 4;
  string invited_by = 5;        // actor_id
  string invited_actor_id = 6;  // who is being invited
  string session_title = 7;
  string summary = 8;
  int64 created_at = 9;
}

// --- MQTT Messages ---

// Published to teamclaw/{teamId}/session/{sessionId}/messages
message SessionMessageEnvelope {
  Message message = 1;
}

// Published to teamclaw/{teamId}/session/{sessionId}/meta (retained)
message SessionMetaEnvelope {
  SessionInfo session = 1;
}

// Published to teamclaw/{teamId}/session/{sessionId}/workitems
message WorkItemEvent {
  oneof event {
    WorkItem created = 1;
    WorkItem updated = 2;
    Claim claimed = 3;
    Submission submitted = 4;
  }
}

// Published to teamclaw/{teamId}/session/{sessionId}/presence (retained)
message PresenceList {
  repeated PresenceEntry entries = 1;
}

message PresenceEntry {
  string actor_id = 1;
  bool online = 2;
  int64 last_seen = 3;
}

// Published to teamclaw/{teamId}/user/{userId}/invites
message InviteEnvelope {
  Invite invite = 1;
}

// Published to teamclaw/{teamId}/members (retained)
message TeamMemberList {
  string team_id = 1;
  repeated Actor members = 2;
}

// Published to teamclaw/{teamId}/sessions (retained, by team host)
// Uses SessionIndex message defined above

// --- RPC ---

message RpcRequest {
  string request_id = 1;
  string sender_device_id = 2;
  oneof method {
    CreateSessionRequest create_session = 10;
    JoinSessionRequest join_session = 11;
    FetchSessionRequest fetch_session = 12;
    AddParticipantRequest add_participant = 13;
    RemoveParticipantRequest remove_participant = 14;
    CreateWorkItemRequest create_work_item = 15;
    ClaimWorkItemRequest claim_work_item = 16;
    SubmitWorkItemRequest submit_work_item = 17;
    UpdateWorkItemRequest update_work_item = 18;
    RegisterSessionRequest register_session = 19;  // session host -> team host
  }
}

message RpcResponse {
  string request_id = 1;
  bool success = 2;
  string error = 3;
  oneof result {
    SessionInfo session_info = 10;
    WorkItem work_item = 11;
    Claim claim = 12;
    Submission submission = 13;
  }
}

message CreateSessionRequest {
  SessionType session_type = 1;
  string team_id = 2;
  string title = 3;
  string summary = 4;            // handoff summary for collab forked from control
  repeated string invite_actor_ids = 5;
}

message JoinSessionRequest {
  string session_id = 1;
  Participant participant = 2;
}

message FetchSessionRequest {
  string session_id = 1;
}

message AddParticipantRequest {
  string session_id = 1;
  Participant participant = 2;
}

message RemoveParticipantRequest {
  string session_id = 1;
  string actor_id = 2;
}

message CreateWorkItemRequest {
  string session_id = 1;
  string title = 2;
  string description = 3;
  string parent_id = 4;
}

message ClaimWorkItemRequest {
  string session_id = 1;
  string work_item_id = 2;
}

message SubmitWorkItemRequest {
  string session_id = 1;
  string work_item_id = 2;
  string content = 3;
}

message UpdateWorkItemRequest {
  string session_id = 1;
  string work_item_id = 2;
  WorkItemStatus status = 3;
  string title = 4;
  string description = 5;
}

message RegisterSessionRequest {
  SessionIndexEntry entry = 1;
}
```

- [ ] **Step 2: Update `daemon/build.rs` to compile both protos**

```rust
use std::io::Result;

fn main() -> Result<()> {
    prost_build::compile_protos(
        &["../proto/amux.proto", "../proto/teamclaw.proto"],
        &["../proto/"],
    )?;
    Ok(())
}
```

- [ ] **Step 3: Update `daemon/src/proto.rs` to include teamclaw module**

Add after the existing `amux` module:

```rust
pub mod teamclaw {
    include!(concat!(env!("OUT_DIR"), "/teamclaw.rs"));
}
```

Add `impl_encode!` for key teamclaw types:

```rust
impl_encode!(teamclaw::SessionMessageEnvelope);
impl_encode!(teamclaw::SessionMetaEnvelope);
impl_encode!(teamclaw::WorkItemEvent);
impl_encode!(teamclaw::PresenceList);
impl_encode!(teamclaw::InviteEnvelope);
impl_encode!(teamclaw::TeamMemberList);
impl_encode!(teamclaw::SessionIndex);
impl_encode!(teamclaw::RpcRequest);
impl_encode!(teamclaw::RpcResponse);
```

- [ ] **Step 4: Update `scripts/proto-gen-swift.sh`**

```bash
#!/bin/bash
protoc \
  --swift_out="ios/Packages/AMUXCore/Sources/AMUXCore/Proto" \
  --swift_opt=Visibility=Public \
  --proto_path="proto" \
  "proto/amux.proto" \
  "proto/teamclaw.proto"
```

- [ ] **Step 5: Verify daemon compiles**

Run: `cd daemon && cargo build 2>&1 | tail -5`
Expected: `Finished` with no errors. New types available as `crate::proto::teamclaw::*`.

- [ ] **Step 6: Generate Swift proto and verify**

Run: `./scripts/proto-gen-swift.sh`
Expected: `teamclaw.pb.swift` generated in `ios/Packages/AMUXCore/Sources/AMUXCore/Proto/`.

- [ ] **Step 7: Commit**

```bash
git add -f proto/teamclaw.proto daemon/build.rs daemon/src/proto.rs scripts/proto-gen-swift.sh ios/Packages/AMUXCore/Sources/AMUXCore/Proto/teamclaw.pb.swift
git commit -m "feat(proto): add teamclaw collaboration protobuf schema

Defines Session, Message, WorkItem, Claim, Submission, Invite types,
MQTT envelope wrappers, and RPC request/response messages for the
teamclaw collaboration layer."
```

---

## Task 2: Teamclaw MQTT Topics

**Files:**
- Create: `daemon/src/teamclaw/mod.rs`
- Create: `daemon/src/teamclaw/topics.rs`

- [ ] **Step 1: Create `daemon/src/teamclaw/mod.rs`**

```rust
pub mod topics;

pub use topics::TeamclawTopics;
```

- [ ] **Step 2: Create `daemon/src/teamclaw/topics.rs`**

Follow the pattern in `daemon/src/mqtt/topics.rs` (52 lines). That file builds AMUX topics from a `device_id`. This file builds teamclaw topics from a `team_id` and `device_id`.

```rust
/// MQTT topic builder for the teamclaw collaboration namespace.
///
/// Topic layout:
///   teamclaw/{team_id}/members                                  (retained)
///   teamclaw/{team_id}/sessions                                 (retained)
///   teamclaw/{team_id}/session/{session_id}/messages
///   teamclaw/{team_id}/session/{session_id}/meta                (retained)
///   teamclaw/{team_id}/session/{session_id}/presence            (retained)
///   teamclaw/{team_id}/session/{session_id}/workitems
///   teamclaw/{team_id}/user/{user_id}/invites
///   teamclaw/{team_id}/rpc/{target_device_id}/{request_id}/req
///   teamclaw/{team_id}/rpc/{target_device_id}/{request_id}/res
pub struct TeamclawTopics {
    pub team_id: String,
    pub device_id: String,
}

impl TeamclawTopics {
    pub fn new(team_id: &str, device_id: &str) -> Self {
        Self {
            team_id: team_id.to_string(),
            device_id: device_id.to_string(),
        }
    }

    // --- Team-level ---

    pub fn members(&self) -> String {
        format!("teamclaw/{}/members", self.team_id)
    }

    pub fn sessions(&self) -> String {
        format!("teamclaw/{}/sessions", self.team_id)
    }

    // --- Session-level ---

    pub fn session_messages(&self, session_id: &str) -> String {
        format!("teamclaw/{}/session/{}/messages", self.team_id, session_id)
    }

    pub fn session_meta(&self, session_id: &str) -> String {
        format!("teamclaw/{}/session/{}/meta", self.team_id, session_id)
    }

    pub fn session_presence(&self, session_id: &str) -> String {
        format!("teamclaw/{}/session/{}/presence", self.team_id, session_id)
    }

    pub fn session_workitems(&self, session_id: &str) -> String {
        format!("teamclaw/{}/session/{}/workitems", self.team_id, session_id)
    }

    // --- User-level ---

    pub fn user_invites(&self, user_id: &str) -> String {
        format!("teamclaw/{}/user/{}/invites", self.team_id, user_id)
    }

    // --- RPC ---

    pub fn rpc_request(&self, target_device_id: &str, request_id: &str) -> String {
        format!(
            "teamclaw/{}/rpc/{}/{}/req",
            self.team_id, target_device_id, request_id
        )
    }

    pub fn rpc_response(&self, target_device_id: &str, request_id: &str) -> String {
        format!(
            "teamclaw/{}/rpc/{}/{}/res",
            self.team_id, target_device_id, request_id
        )
    }

    /// Subscribe pattern for incoming RPC requests targeted at this device.
    pub fn rpc_incoming_requests(&self) -> String {
        format!("teamclaw/{}/rpc/{}/+/req", self.team_id, self.device_id)
    }

    /// Subscribe pattern for all session messages (wildcard).
    pub fn all_session_messages(&self) -> String {
        format!("teamclaw/{}/session/+/messages", self.team_id)
    }

    /// Subscribe pattern for all session metadata (wildcard).
    pub fn all_session_meta(&self) -> String {
        format!("teamclaw/{}/session/+/meta", self.team_id)
    }

    /// Subscribe pattern for all work item events (wildcard).
    pub fn all_session_workitems(&self) -> String {
        format!("teamclaw/{}/session/+/workitems", self.team_id)
    }
}
```

- [ ] **Step 3: Register teamclaw module in `daemon/src/main.rs`**

Add `mod teamclaw;` alongside the existing module declarations near the top of main.rs.

- [ ] **Step 4: Verify compilation**

Run: `cd daemon && cargo build 2>&1 | tail -5`
Expected: `Finished` with no errors (warnings about unused code are fine at this stage).

- [ ] **Step 5: Commit**

```bash
git add -f daemon/src/teamclaw/mod.rs daemon/src/teamclaw/topics.rs daemon/src/main.rs
git commit -m "feat(daemon): add teamclaw MQTT topic builder

Separate namespace from AMUX runtime topics. Covers team-level,
session-level, user-level, and RPC topic patterns."
```

---

## Task 3: Teamclaw Session Store

**Files:**
- Create: `daemon/src/teamclaw/session_store.rs`
- Modify: `daemon/src/teamclaw/mod.rs`

- [ ] **Step 1: Create `daemon/src/teamclaw/session_store.rs`**

Follow the pattern in `daemon/src/config/session_store.rs` (84 lines) — TOML file with load/save and lookup methods. This store holds teamclaw session metadata (not AMUX agent sessions).

```rust
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use std::path::Path;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TeamclawSessionStore {
    #[serde(default)]
    pub sessions: Vec<StoredCollabSession>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StoredCollabSession {
    pub session_id: String,
    pub session_type: String,       // "control" or "collab"
    pub team_id: String,
    pub title: String,
    pub host_device_id: String,
    pub created_by: String,         // actor_id
    pub created_at: DateTime<Utc>,
    pub summary: String,
    #[serde(default)]
    pub participants: Vec<StoredParticipant>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StoredParticipant {
    pub actor_id: String,
    pub actor_type: String,         // "human", "personal_agent", "role_agent"
    pub display_name: String,
    pub joined_at: DateTime<Utc>,
}

impl TeamclawSessionStore {
    pub fn load(path: &Path) -> Self {
        match std::fs::read_to_string(path) {
            Ok(content) => toml::from_str(&content).unwrap_or_default(),
            Err(_) => Self::default(),
        }
    }

    pub fn save(&self, path: &Path) -> std::io::Result<()> {
        let content = toml::to_string_pretty(self)
            .map_err(|e| std::io::Error::new(std::io::ErrorKind::Other, e))?;
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        std::fs::write(path, content)
    }

    pub fn upsert(&mut self, session: StoredCollabSession) {
        if let Some(existing) = self.sessions.iter_mut().find(|s| s.session_id == session.session_id) {
            *existing = session;
        } else {
            self.sessions.push(session);
        }
    }

    pub fn find_by_id(&self, session_id: &str) -> Option<&StoredCollabSession> {
        self.sessions.iter().find(|s| s.session_id == session_id)
    }

    pub fn find_by_id_mut(&mut self, session_id: &str) -> Option<&mut StoredCollabSession> {
        self.sessions.iter_mut().find(|s| s.session_id == session_id)
    }

    pub fn remove(&mut self, session_id: &str) -> bool {
        let len = self.sessions.len();
        self.sessions.retain(|s| s.session_id != session_id);
        self.sessions.len() < len
    }

    pub fn hosted_sessions(&self, device_id: &str) -> Vec<&StoredCollabSession> {
        self.sessions.iter().filter(|s| s.host_device_id == device_id).collect()
    }

    pub fn to_proto_index(&self) -> crate::proto::teamclaw::SessionIndex {
        crate::proto::teamclaw::SessionIndex {
            sessions: self.sessions.iter().map(|s| {
                crate::proto::teamclaw::SessionIndexEntry {
                    session_id: s.session_id.clone(),
                    session_type: match s.session_type.as_str() {
                        "control" => crate::proto::teamclaw::SessionType::Control as i32,
                        "collab" => crate::proto::teamclaw::SessionType::Collab as i32,
                        _ => 0,
                    },
                    title: s.title.clone(),
                    host_device_id: s.host_device_id.clone(),
                    created_at: s.created_at.timestamp(),
                    participant_count: s.participants.len() as i32,
                    last_message_preview: String::new(),
                    last_message_at: 0,
                }
            }).collect(),
        }
    }

    pub fn to_proto_session_info(&self, session_id: &str) -> Option<crate::proto::teamclaw::SessionInfo> {
        self.find_by_id(session_id).map(|s| {
            crate::proto::teamclaw::SessionInfo {
                session_id: s.session_id.clone(),
                session_type: match s.session_type.as_str() {
                    "control" => crate::proto::teamclaw::SessionType::Control as i32,
                    "collab" => crate::proto::teamclaw::SessionType::Collab as i32,
                    _ => 0,
                },
                team_id: s.team_id.clone(),
                title: s.title.clone(),
                host_device_id: s.host_device_id.clone(),
                created_by: s.created_by.clone(),
                created_at: s.created_at.timestamp(),
                participants: s.participants.iter().map(|p| {
                    crate::proto::teamclaw::Participant {
                        actor_id: p.actor_id.clone(),
                        actor_type: match p.actor_type.as_str() {
                            "human" => crate::proto::teamclaw::ActorType::Human as i32,
                            "personal_agent" => crate::proto::teamclaw::ActorType::PersonalAgent as i32,
                            "role_agent" => crate::proto::teamclaw::ActorType::RoleAgent as i32,
                            _ => 0,
                        },
                        display_name: p.display_name.clone(),
                        joined_at: p.joined_at.timestamp(),
                    }
                }).collect(),
                summary: s.summary.clone(),
            }
        })
    }
}

impl Default for TeamclawSessionStore {
    fn default() -> Self {
        Self { sessions: Vec::new() }
    }
}
```

- [ ] **Step 2: Export from `daemon/src/teamclaw/mod.rs`**

```rust
pub mod topics;
pub mod session_store;

pub use topics::TeamclawTopics;
pub use session_store::{TeamclawSessionStore, StoredCollabSession, StoredParticipant};
```

- [ ] **Step 3: Verify compilation**

Run: `cd daemon && cargo build 2>&1 | tail -5`
Expected: `Finished` with no errors.

- [ ] **Step 4: Commit**

```bash
git add -f daemon/src/teamclaw/session_store.rs daemon/src/teamclaw/mod.rs
git commit -m "feat(daemon): add teamclaw session store

TOML-backed storage for control and collab session metadata,
participants, and proto conversion methods."
```

---

## Task 4: Message Store & Work Item Store

**Files:**
- Create: `daemon/src/teamclaw/message_store.rs`
- Create: `daemon/src/teamclaw/work_item_store.rs`
- Modify: `daemon/src/teamclaw/mod.rs`

- [ ] **Step 1: Create `daemon/src/teamclaw/message_store.rs`**

Messages are stored per-session in separate TOML files under `~/.config/amux/teamclaw/sessions/{session_id}/messages.toml`. This avoids a single large file.

```rust
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct MessageStore {
    #[serde(default)]
    pub messages: Vec<StoredMessage>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StoredMessage {
    pub message_id: String,
    pub session_id: String,
    pub sender_actor_id: String,
    pub kind: String,               // "text", "system", "work_event"
    pub content: String,
    pub created_at: DateTime<Utc>,
    pub reply_to_message_id: String,
    #[serde(default)]
    pub mentions: Vec<String>,
}

impl MessageStore {
    pub fn session_dir(base_dir: &Path, session_id: &str) -> PathBuf {
        base_dir.join("teamclaw").join("sessions").join(session_id)
    }

    pub fn file_path(base_dir: &Path, session_id: &str) -> PathBuf {
        Self::session_dir(base_dir, session_id).join("messages.toml")
    }

    pub fn load(base_dir: &Path, session_id: &str) -> Self {
        let path = Self::file_path(base_dir, session_id);
        match std::fs::read_to_string(&path) {
            Ok(content) => toml::from_str(&content).unwrap_or_default(),
            Err(_) => Self::default(),
        }
    }

    pub fn save(&self, base_dir: &Path, session_id: &str) -> std::io::Result<()> {
        let path = Self::file_path(base_dir, session_id);
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let content = toml::to_string_pretty(self)
            .map_err(|e| std::io::Error::new(std::io::ErrorKind::Other, e))?;
        std::fs::write(path, content)
    }

    pub fn append(&mut self, message: StoredMessage) {
        self.messages.push(message);
    }

    pub fn recent(&self, n: usize) -> &[StoredMessage] {
        let start = self.messages.len().saturating_sub(n);
        &self.messages[start..]
    }

    pub fn to_proto(&self, msg: &StoredMessage) -> crate::proto::teamclaw::Message {
        crate::proto::teamclaw::Message {
            message_id: msg.message_id.clone(),
            session_id: msg.session_id.clone(),
            sender_actor_id: msg.sender_actor_id.clone(),
            kind: match msg.kind.as_str() {
                "text" => crate::proto::teamclaw::MessageKind::Text as i32,
                "system" => crate::proto::teamclaw::MessageKind::System as i32,
                "work_event" => crate::proto::teamclaw::MessageKind::WorkEvent as i32,
                _ => 0,
            },
            content: msg.content.clone(),
            created_at: msg.created_at.timestamp(),
            reply_to_message_id: msg.reply_to_message_id.clone(),
            mentions: msg.mentions.clone(),
        }
    }
}
```

- [ ] **Step 2: Create `daemon/src/teamclaw/work_item_store.rs`**

```rust
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use std::path::Path;

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct WorkItemStore {
    #[serde(default)]
    pub items: Vec<StoredWorkItem>,
    #[serde(default)]
    pub claims: Vec<StoredClaim>,
    #[serde(default)]
    pub submissions: Vec<StoredSubmission>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StoredWorkItem {
    pub work_item_id: String,
    pub session_id: String,
    pub title: String,
    pub description: String,
    pub status: String,             // "open", "in_progress", "done"
    pub parent_id: String,
    pub created_by: String,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StoredClaim {
    pub claim_id: String,
    pub work_item_id: String,
    pub actor_id: String,
    pub claimed_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StoredSubmission {
    pub submission_id: String,
    pub work_item_id: String,
    pub actor_id: String,
    pub content: String,
    pub submitted_at: DateTime<Utc>,
}

impl WorkItemStore {
    pub fn load(base_dir: &Path, session_id: &str) -> Self {
        let path = base_dir.join("teamclaw").join("sessions").join(session_id).join("workitems.toml");
        match std::fs::read_to_string(&path) {
            Ok(content) => toml::from_str(&content).unwrap_or_default(),
            Err(_) => Self::default(),
        }
    }

    pub fn save(&self, base_dir: &Path, session_id: &str) -> std::io::Result<()> {
        let dir = base_dir.join("teamclaw").join("sessions").join(session_id);
        std::fs::create_dir_all(&dir)?;
        let content = toml::to_string_pretty(self)
            .map_err(|e| std::io::Error::new(std::io::ErrorKind::Other, e))?;
        std::fs::write(dir.join("workitems.toml"), content)
    }

    pub fn add_item(&mut self, item: StoredWorkItem) {
        self.items.push(item);
    }

    pub fn find_item(&self, work_item_id: &str) -> Option<&StoredWorkItem> {
        self.items.iter().find(|i| i.work_item_id == work_item_id)
    }

    pub fn find_item_mut(&mut self, work_item_id: &str) -> Option<&mut StoredWorkItem> {
        self.items.iter_mut().find(|i| i.work_item_id == work_item_id)
    }

    pub fn add_claim(&mut self, claim: StoredClaim) {
        // Also update work item status to in_progress
        if let Some(item) = self.find_item_mut(&claim.work_item_id) {
            if item.status == "open" {
                item.status = "in_progress".to_string();
            }
        }
        self.claims.push(claim);
    }

    pub fn add_submission(&mut self, submission: StoredSubmission) {
        self.submissions.push(submission);
    }

    pub fn claims_for_item(&self, work_item_id: &str) -> Vec<&StoredClaim> {
        self.claims.iter().filter(|c| c.work_item_id == work_item_id).collect()
    }

    pub fn submissions_for_item(&self, work_item_id: &str) -> Vec<&StoredSubmission> {
        self.submissions.iter().filter(|s| s.work_item_id == work_item_id).collect()
    }

    pub fn items_claimed_by(&self, actor_id: &str) -> Vec<&str> {
        self.claims.iter()
            .filter(|c| c.actor_id == actor_id)
            .map(|c| c.work_item_id.as_str())
            .collect()
    }

    pub fn to_proto_work_item(&self, item: &StoredWorkItem) -> crate::proto::teamclaw::WorkItem {
        crate::proto::teamclaw::WorkItem {
            work_item_id: item.work_item_id.clone(),
            session_id: item.session_id.clone(),
            title: item.title.clone(),
            description: item.description.clone(),
            status: match item.status.as_str() {
                "open" => crate::proto::teamclaw::WorkItemStatus::Open as i32,
                "in_progress" => crate::proto::teamclaw::WorkItemStatus::InProgress as i32,
                "done" => crate::proto::teamclaw::WorkItemStatus::Done as i32,
                _ => 0,
            },
            parent_id: item.parent_id.clone(),
            created_by: item.created_by.clone(),
            created_at: item.created_at.timestamp(),
            claims: self.claims_for_item(&item.work_item_id).iter().map(|c| {
                crate::proto::teamclaw::Claim {
                    claim_id: c.claim_id.clone(),
                    work_item_id: c.work_item_id.clone(),
                    actor_id: c.actor_id.clone(),
                    claimed_at: c.claimed_at.timestamp(),
                }
            }).collect(),
            submissions: self.submissions_for_item(&item.work_item_id).iter().map(|s| {
                crate::proto::teamclaw::Submission {
                    submission_id: s.submission_id.clone(),
                    work_item_id: s.work_item_id.clone(),
                    actor_id: s.actor_id.clone(),
                    content: s.content.clone(),
                    submitted_at: s.submitted_at.timestamp(),
                }
            }).collect(),
        }
    }
}
```

- [ ] **Step 3: Update `daemon/src/teamclaw/mod.rs`**

```rust
pub mod topics;
pub mod session_store;
pub mod message_store;
pub mod work_item_store;

pub use topics::TeamclawTopics;
pub use session_store::{TeamclawSessionStore, StoredCollabSession, StoredParticipant};
pub use message_store::{MessageStore, StoredMessage};
pub use work_item_store::{WorkItemStore, StoredWorkItem, StoredClaim, StoredSubmission};
```

- [ ] **Step 4: Verify compilation**

Run: `cd daemon && cargo build 2>&1 | tail -5`
Expected: `Finished` with no errors.

- [ ] **Step 5: Commit**

```bash
git add -f daemon/src/teamclaw/message_store.rs daemon/src/teamclaw/work_item_store.rs daemon/src/teamclaw/mod.rs
git commit -m "feat(daemon): add message and work item stores

Per-session TOML storage for messages, work items, claims, and
submissions. Messages stored in separate files per session to
avoid a single large file."
```

---

## Task 5: MQTT RPC Handler

**Files:**
- Create: `daemon/src/teamclaw/rpc.rs`
- Modify: `daemon/src/teamclaw/mod.rs`

- [ ] **Step 1: Create `daemon/src/teamclaw/rpc.rs`**

This handles the request/reply pattern over MQTT. An RPC client publishes to `teamclaw/{teamId}/rpc/{targetDeviceId}/{requestId}/req`, and the target amuxd responds on the matching `/res` topic.

```rust
use crate::proto::teamclaw::{RpcRequest, RpcResponse};
use prost::Message as ProstMessage;
use rumqttc::AsyncClient;
use rumqttc::QoS;
use std::collections::HashMap;
use tokio::sync::oneshot;
use uuid::Uuid;

/// Server-side: receives RPC requests and sends responses.
pub struct RpcServer {
    client: AsyncClient,
    team_id: String,
    device_id: String,
}

impl RpcServer {
    pub fn new(client: AsyncClient, team_id: &str, device_id: &str) -> Self {
        Self {
            client,
            team_id: team_id.to_string(),
            device_id: device_id.to_string(),
        }
    }

    /// Parse an incoming RPC request from a publish on the rpc/.../req topic.
    /// Returns (request_id, RpcRequest) if valid.
    pub fn parse_request(topic: &str, payload: &[u8]) -> Option<(String, RpcRequest)> {
        // Topic format: teamclaw/{teamId}/rpc/{targetDeviceId}/{requestId}/req
        let parts: Vec<&str> = topic.split('/').collect();
        if parts.len() != 6 || parts[5] != "req" {
            return None;
        }
        let request_id = parts[4].to_string();
        let request = RpcRequest::decode(payload).ok()?;
        Some((request_id, request))
    }

    /// Send an RPC response back to the requester.
    pub async fn respond(
        &self,
        request: &RpcRequest,
        request_id: &str,
        response: RpcResponse,
    ) -> Result<(), rumqttc::ClientError> {
        let topic = format!(
            "teamclaw/{}/rpc/{}/{}/res",
            self.team_id, request.sender_device_id, request_id
        );
        let payload = response.encode_to_vec();
        self.client.publish(topic, QoS::AtLeastOnce, false, payload).await
    }
}

/// Client-side: sends RPC requests and waits for responses.
pub struct RpcClient {
    client: AsyncClient,
    team_id: String,
    device_id: String,
    pending: HashMap<String, oneshot::Sender<RpcResponse>>,
}

impl RpcClient {
    pub fn new(client: AsyncClient, team_id: &str, device_id: &str) -> Self {
        Self {
            client,
            team_id: team_id.to_string(),
            device_id: device_id.to_string(),
            pending: HashMap::new(),
        }
    }

    /// Send an RPC request and get a oneshot receiver for the response.
    pub async fn request(
        &mut self,
        target_device_id: &str,
        request: RpcRequest,
    ) -> Result<oneshot::Receiver<RpcResponse>, rumqttc::ClientError> {
        let request_id = request.request_id.clone();
        let topic = format!(
            "teamclaw/{}/rpc/{}/{}/req",
            self.team_id, target_device_id, request_id
        );
        let payload = request.encode_to_vec();

        let (tx, rx) = oneshot::channel();
        self.pending.insert(request_id, tx);

        self.client.publish(topic, QoS::AtLeastOnce, false, payload).await?;
        Ok(rx)
    }

    /// Feed an incoming RPC response (from the response topic subscription).
    /// Returns true if it matched a pending request.
    pub fn handle_response(&mut self, topic: &str, payload: &[u8]) -> bool {
        // Topic format: teamclaw/{teamId}/rpc/{deviceId}/{requestId}/res
        let parts: Vec<&str> = topic.split('/').collect();
        if parts.len() != 6 || parts[5] != "res" {
            return false;
        }
        let request_id = parts[4];
        if let Some(tx) = self.pending.remove(request_id) {
            if let Ok(response) = RpcResponse::decode(payload) {
                let _ = tx.send(response);
                return true;
            }
        }
        false
    }

    /// Generate a new request ID.
    pub fn new_request_id() -> String {
        Uuid::new_v4().to_string()[..8].to_string()
    }
}
```

- [ ] **Step 2: Update `daemon/src/teamclaw/mod.rs`**

Add:
```rust
pub mod rpc;
pub use rpc::{RpcServer, RpcClient};
```

- [ ] **Step 3: Verify compilation**

Run: `cd daemon && cargo build 2>&1 | tail -5`
Expected: `Finished` with no errors.

- [ ] **Step 4: Commit**

```bash
git add -f daemon/src/teamclaw/rpc.rs daemon/src/teamclaw/mod.rs
git commit -m "feat(daemon): add MQTT RPC request/reply handler

Server-side parses incoming requests and sends responses.
Client-side sends requests with oneshot channels for async
response handling. Routed by target device ID in topic path."
```

---

## Task 6: Session Manager (Core Lifecycle)

**Files:**
- Create: `daemon/src/teamclaw/session_manager.rs`
- Modify: `daemon/src/teamclaw/mod.rs`

- [ ] **Step 1: Create `daemon/src/teamclaw/session_manager.rs`**

This is the central coordinator. It handles RPC requests, manages stores, publishes MQTT events, and routes messages to agents.

```rust
use crate::proto::teamclaw::{self, RpcRequest, RpcResponse, SessionInfo};
use crate::teamclaw::{
    MessageStore, StoredCollabSession, StoredMessage, StoredParticipant,
    TeamclawSessionStore, TeamclawTopics, WorkItemStore, StoredWorkItem,
    StoredClaim, StoredSubmission, RpcServer,
};
use chrono::Utc;
use prost::Message as ProstMessage;
use rumqttc::{AsyncClient, QoS};
use std::path::PathBuf;
use tracing::{info, warn};
use uuid::Uuid;

pub struct SessionManager {
    topics: TeamclawTopics,
    client: AsyncClient,
    rpc_server: RpcServer,
    sessions: TeamclawSessionStore,
    sessions_path: PathBuf,
    config_dir: PathBuf,        // base for per-session message/workitem stores
    device_id: String,
    team_id: String,
    is_team_host: bool,
}

impl SessionManager {
    pub fn new(
        client: AsyncClient,
        team_id: &str,
        device_id: &str,
        config_dir: PathBuf,
        is_team_host: bool,
    ) -> Self {
        let sessions_path = config_dir.join("teamclaw").join("sessions.toml");
        let sessions = TeamclawSessionStore::load(&sessions_path);
        let topics = TeamclawTopics::new(team_id, device_id);
        let rpc_server = RpcServer::new(client.clone(), team_id, device_id);

        Self {
            topics,
            client,
            rpc_server,
            sessions,
            sessions_path,
            config_dir,
            device_id: device_id.to_string(),
            team_id: team_id.to_string(),
            is_team_host,
        }
    }

    /// Subscribe to all teamclaw topics this device needs.
    pub async fn subscribe_all(&self) -> Result<(), rumqttc::ClientError> {
        // Team-level
        self.client.subscribe(&self.topics.members(), QoS::AtLeastOnce).await?;
        self.client.subscribe(&self.topics.sessions(), QoS::AtLeastOnce).await?;

        // RPC requests targeted at this device
        self.client.subscribe(&self.topics.rpc_incoming_requests(), QoS::AtLeastOnce).await?;

        // RPC responses for requests we send
        let rpc_responses = format!("teamclaw/{}/rpc/{}/+/res", self.team_id, self.device_id);
        self.client.subscribe(&rpc_responses, QoS::AtLeastOnce).await?;

        // Subscribe to session topics for sessions we host or participate in
        for session in &self.sessions.sessions {
            self.subscribe_session(&session.session_id).await?;
        }

        Ok(())
    }

    async fn subscribe_session(&self, session_id: &str) -> Result<(), rumqttc::ClientError> {
        self.client.subscribe(&self.topics.session_messages(session_id), QoS::AtLeastOnce).await?;
        self.client.subscribe(&self.topics.session_meta(session_id), QoS::AtLeastOnce).await?;
        self.client.subscribe(&self.topics.session_workitems(session_id), QoS::AtLeastOnce).await?;
        self.client.subscribe(&self.topics.session_presence(session_id), QoS::AtLeastOnce).await?;
        Ok(())
    }

    /// Handle an incoming RPC request.
    pub async fn handle_rpc_request(&mut self, topic: &str, payload: &[u8]) {
        let (request_id, request) = match RpcServer::parse_request(topic, payload) {
            Some(r) => r,
            None => return,
        };

        let response = match &request.method {
            Some(teamclaw::rpc_request::Method::CreateSession(req)) => {
                self.handle_create_session(req).await
            }
            Some(teamclaw::rpc_request::Method::FetchSession(req)) => {
                self.handle_fetch_session(req)
            }
            Some(teamclaw::rpc_request::Method::JoinSession(req)) => {
                self.handle_join_session(req).await
            }
            Some(teamclaw::rpc_request::Method::AddParticipant(req)) => {
                self.handle_add_participant(req).await
            }
            Some(teamclaw::rpc_request::Method::RemoveParticipant(req)) => {
                self.handle_remove_participant(req).await
            }
            Some(teamclaw::rpc_request::Method::CreateWorkItem(req)) => {
                self.handle_create_work_item(req).await
            }
            Some(teamclaw::rpc_request::Method::ClaimWorkItem(req)) => {
                self.handle_claim_work_item(req).await
            }
            Some(teamclaw::rpc_request::Method::SubmitWorkItem(req)) => {
                self.handle_submit_work_item(req).await
            }
            Some(teamclaw::rpc_request::Method::UpdateWorkItem(req)) => {
                self.handle_update_work_item(req).await
            }
            Some(teamclaw::rpc_request::Method::RegisterSession(req)) => {
                self.handle_register_session(req).await
            }
            None => RpcResponse {
                request_id: request_id.clone(),
                success: false,
                error: "unknown method".to_string(),
                result: None,
            },
        };

        if let Err(e) = self.rpc_server.respond(&request, &request_id, response).await {
            warn!("Failed to send RPC response: {}", e);
        }
    }

    async fn handle_create_session(
        &mut self,
        req: &teamclaw::CreateSessionRequest,
    ) -> RpcResponse {
        let session_id = Uuid::new_v4().to_string()[..8].to_string();
        let now = Utc::now();

        let session = StoredCollabSession {
            session_id: session_id.clone(),
            session_type: match req.session_type {
                x if x == teamclaw::SessionType::Control as i32 => "control".to_string(),
                _ => "collab".to_string(),
            },
            team_id: req.team_id.clone(),
            title: req.title.clone(),
            host_device_id: self.device_id.clone(),
            created_by: request.sender_device_id.clone(), // use sender as creator; refine to actor_id when auth context is wired
            created_at: now,
            summary: req.summary.clone(),
            participants: Vec::new(),
        };

        self.sessions.upsert(session);
        let _ = self.sessions.save(&self.sessions_path);

        // If this is a collab session with a summary, publish the summary as first system message
        if !req.summary.is_empty() {
            let msg = StoredMessage {
                message_id: Uuid::new_v4().to_string()[..8].to_string(),
                session_id: session_id.clone(),
                sender_actor_id: "system".to_string(),
                kind: "system".to_string(),
                content: req.summary.clone(),
                created_at: now,
                reply_to_message_id: String::new(),
                mentions: Vec::new(),
            };
            let mut msg_store = MessageStore::load(&self.config_dir, &session_id);
            msg_store.append(msg.clone());
            let _ = msg_store.save(&self.config_dir, &session_id);

            // Publish to session messages topic
            let envelope = teamclaw::SessionMessageEnvelope {
                message: Some(msg_store.to_proto(&msg)),
            };
            let topic = self.topics.session_messages(&session_id);
            let _ = self.client.publish(topic, QoS::AtLeastOnce, false, envelope.encode_to_vec()).await;
        }

        // Publish session metadata (retained)
        self.publish_session_meta(&session_id).await;

        // Subscribe to the new session's topics
        let _ = self.subscribe_session(&session_id).await;

        // Send invites
        for actor_id in &req.invite_actor_ids {
            let invite = teamclaw::Invite {
                invite_id: Uuid::new_v4().to_string()[..8].to_string(),
                session_id: session_id.clone(),
                team_id: self.team_id.clone(),
                host_device_id: self.device_id.clone(),
                invited_by: String::new(),
                invited_actor_id: actor_id.clone(),
                session_title: req.title.clone(),
                summary: req.summary.clone(),
                created_at: now.timestamp(),
            };
            let envelope = teamclaw::InviteEnvelope { invite: Some(invite) };
            let topic = self.topics.user_invites(actor_id);
            let _ = self.client.publish(topic, QoS::AtLeastOnce, false, envelope.encode_to_vec()).await;
        }

        let session_info = self.sessions.to_proto_session_info(&session_id);
        info!("Created session: {} (type: {})", session_id, req.session_type);

        RpcResponse {
            request_id: String::new(),
            success: true,
            error: String::new(),
            result: session_info.map(teamclaw::rpc_response::Result::SessionInfo),
        }
    }

    fn handle_fetch_session(
        &self,
        req: &teamclaw::FetchSessionRequest,
    ) -> RpcResponse {
        match self.sessions.to_proto_session_info(&req.session_id) {
            Some(info) => RpcResponse {
                request_id: String::new(),
                success: true,
                error: String::new(),
                result: Some(teamclaw::rpc_response::Result::SessionInfo(info)),
            },
            None => RpcResponse {
                request_id: String::new(),
                success: false,
                error: format!("session {} not found", req.session_id),
                result: None,
            },
        }
    }

    async fn handle_join_session(
        &mut self,
        req: &teamclaw::JoinSessionRequest,
    ) -> RpcResponse {
        let participant = match &req.participant {
            Some(p) => p,
            None => return RpcResponse {
                request_id: String::new(),
                success: false,
                error: "missing participant".to_string(),
                result: None,
            },
        };

        if let Some(session) = self.sessions.find_by_id_mut(&req.session_id) {
            // Don't add duplicates
            if !session.participants.iter().any(|p| p.actor_id == participant.actor_id) {
                session.participants.push(StoredParticipant {
                    actor_id: participant.actor_id.clone(),
                    actor_type: match participant.actor_type {
                        x if x == teamclaw::ActorType::Human as i32 => "human".to_string(),
                        x if x == teamclaw::ActorType::PersonalAgent as i32 => "personal_agent".to_string(),
                        x if x == teamclaw::ActorType::RoleAgent as i32 => "role_agent".to_string(),
                        _ => "unknown".to_string(),
                    },
                    display_name: participant.display_name.clone(),
                    joined_at: Utc::now(),
                });
                let _ = self.sessions.save(&self.sessions_path);
            }
            self.publish_session_meta(&req.session_id).await;

            let session_info = self.sessions.to_proto_session_info(&req.session_id);
            RpcResponse {
                request_id: String::new(),
                success: true,
                error: String::new(),
                result: session_info.map(teamclaw::rpc_response::Result::SessionInfo),
            }
        } else {
            RpcResponse {
                request_id: String::new(),
                success: false,
                error: format!("session {} not found", req.session_id),
                result: None,
            }
        }
    }

    async fn handle_add_participant(
        &mut self,
        req: &teamclaw::AddParticipantRequest,
    ) -> RpcResponse {
        // Reuse join logic
        let join_req = teamclaw::JoinSessionRequest {
            session_id: req.session_id.clone(),
            participant: req.participant.clone(),
        };
        self.handle_join_session(&join_req).await
    }

    async fn handle_remove_participant(
        &mut self,
        req: &teamclaw::RemoveParticipantRequest,
    ) -> RpcResponse {
        if let Some(session) = self.sessions.find_by_id_mut(&req.session_id) {
            session.participants.retain(|p| p.actor_id != req.actor_id);
            let _ = self.sessions.save(&self.sessions_path);
            self.publish_session_meta(&req.session_id).await;
            RpcResponse {
                request_id: String::new(),
                success: true,
                error: String::new(),
                result: None,
            }
        } else {
            RpcResponse {
                request_id: String::new(),
                success: false,
                error: format!("session {} not found", req.session_id),
                result: None,
            }
        }
    }

    async fn handle_create_work_item(
        &mut self,
        req: &teamclaw::CreateWorkItemRequest,
    ) -> RpcResponse {
        let item = StoredWorkItem {
            work_item_id: Uuid::new_v4().to_string()[..8].to_string(),
            session_id: req.session_id.clone(),
            title: req.title.clone(),
            description: req.description.clone(),
            status: "open".to_string(),
            parent_id: req.parent_id.clone(),
            created_by: String::new(),
            created_at: Utc::now(),
        };

        let mut store = WorkItemStore::load(&self.config_dir, &req.session_id);
        let proto_item = store.to_proto_work_item(&item);
        store.add_item(item);
        let _ = store.save(&self.config_dir, &req.session_id);

        // Publish work item event
        let event = teamclaw::WorkItemEvent {
            event: Some(teamclaw::work_item_event::Event::Created(proto_item.clone())),
        };
        let topic = self.topics.session_workitems(&req.session_id);
        let _ = self.client.publish(topic, QoS::AtLeastOnce, false, event.encode_to_vec()).await;

        RpcResponse {
            request_id: String::new(),
            success: true,
            error: String::new(),
            result: Some(teamclaw::rpc_response::Result::WorkItem(proto_item)),
        }
    }

    async fn handle_claim_work_item(
        &mut self,
        req: &teamclaw::ClaimWorkItemRequest,
    ) -> RpcResponse {
        let mut store = WorkItemStore::load(&self.config_dir, &req.session_id);
        let claim = StoredClaim {
            claim_id: Uuid::new_v4().to_string()[..8].to_string(),
            work_item_id: req.work_item_id.clone(),
            actor_id: String::new(), // filled by caller context
            claimed_at: Utc::now(),
        };
        let proto_claim = teamclaw::Claim {
            claim_id: claim.claim_id.clone(),
            work_item_id: claim.work_item_id.clone(),
            actor_id: claim.actor_id.clone(),
            claimed_at: claim.claimed_at.timestamp(),
        };
        store.add_claim(claim);
        let _ = store.save(&self.config_dir, &req.session_id);

        // Publish claim event
        let event = teamclaw::WorkItemEvent {
            event: Some(teamclaw::work_item_event::Event::Claimed(proto_claim.clone())),
        };
        let topic = self.topics.session_workitems(&req.session_id);
        let _ = self.client.publish(topic, QoS::AtLeastOnce, false, event.encode_to_vec()).await;

        RpcResponse {
            request_id: String::new(),
            success: true,
            error: String::new(),
            result: Some(teamclaw::rpc_response::Result::Claim(proto_claim)),
        }
    }

    async fn handle_submit_work_item(
        &mut self,
        req: &teamclaw::SubmitWorkItemRequest,
    ) -> RpcResponse {
        let mut store = WorkItemStore::load(&self.config_dir, &req.session_id);
        let submission = StoredSubmission {
            submission_id: Uuid::new_v4().to_string()[..8].to_string(),
            work_item_id: req.work_item_id.clone(),
            actor_id: String::new(),
            content: req.content.clone(),
            submitted_at: Utc::now(),
        };
        let proto_sub = teamclaw::Submission {
            submission_id: submission.submission_id.clone(),
            work_item_id: submission.work_item_id.clone(),
            actor_id: submission.actor_id.clone(),
            content: submission.content.clone(),
            submitted_at: submission.submitted_at.timestamp(),
        };
        store.add_submission(submission);
        let _ = store.save(&self.config_dir, &req.session_id);

        let event = teamclaw::WorkItemEvent {
            event: Some(teamclaw::work_item_event::Event::Submitted(proto_sub.clone())),
        };
        let topic = self.topics.session_workitems(&req.session_id);
        let _ = self.client.publish(topic, QoS::AtLeastOnce, false, event.encode_to_vec()).await;

        RpcResponse {
            request_id: String::new(),
            success: true,
            error: String::new(),
            result: Some(teamclaw::rpc_response::Result::Submission(proto_sub)),
        }
    }

    async fn handle_update_work_item(
        &mut self,
        req: &teamclaw::UpdateWorkItemRequest,
    ) -> RpcResponse {
        let mut store = WorkItemStore::load(&self.config_dir, &req.session_id);
        if let Some(item) = store.find_item_mut(&req.work_item_id) {
            if req.status != 0 {
                item.status = match req.status {
                    x if x == teamclaw::WorkItemStatus::Open as i32 => "open",
                    x if x == teamclaw::WorkItemStatus::InProgress as i32 => "in_progress",
                    x if x == teamclaw::WorkItemStatus::Done as i32 => "done",
                    _ => "open",
                }.to_string();
            }
            if !req.title.is_empty() { item.title = req.title.clone(); }
            if !req.description.is_empty() { item.description = req.description.clone(); }

            let proto_item = store.to_proto_work_item(item);
            let _ = store.save(&self.config_dir, &req.session_id);

            let event = teamclaw::WorkItemEvent {
                event: Some(teamclaw::work_item_event::Event::Updated(proto_item.clone())),
            };
            let topic = self.topics.session_workitems(&req.session_id);
            let _ = self.client.publish(topic, QoS::AtLeastOnce, false, event.encode_to_vec()).await;

            RpcResponse {
                request_id: String::new(),
                success: true,
                error: String::new(),
                result: Some(teamclaw::rpc_response::Result::WorkItem(proto_item)),
            }
        } else {
            RpcResponse {
                request_id: String::new(),
                success: false,
                error: format!("work item {} not found", req.work_item_id),
                result: None,
            }
        }
    }

    /// Team host only: register a session in the global index.
    async fn handle_register_session(
        &mut self,
        req: &teamclaw::RegisterSessionRequest,
    ) -> RpcResponse {
        if !self.is_team_host {
            return RpcResponse {
                request_id: String::new(),
                success: false,
                error: "not team host".to_string(),
                result: None,
            };
        }

        // Add to local session store as a reference entry
        if let Some(entry) = &req.entry {
            let session = StoredCollabSession {
                session_id: entry.session_id.clone(),
                session_type: match entry.session_type {
                    x if x == teamclaw::SessionType::Control as i32 => "control".to_string(),
                    _ => "collab".to_string(),
                },
                team_id: self.team_id.clone(),
                title: entry.title.clone(),
                host_device_id: entry.host_device_id.clone(),
                created_by: String::new(),
                created_at: chrono::DateTime::from_timestamp(entry.created_at, 0)
                    .unwrap_or_else(Utc::now),
                summary: String::new(),
                participants: Vec::new(),
            };
            self.sessions.upsert(session);
            let _ = self.sessions.save(&self.sessions_path);
        }

        // Republish session index
        self.publish_session_index().await;

        RpcResponse {
            request_id: String::new(),
            success: true,
            error: String::new(),
            result: None,
        }
    }

    /// Persist an incoming session message (called when this device is session host).
    pub fn persist_message(&self, session_id: &str, message: &teamclaw::Message) {
        let stored = StoredMessage {
            message_id: message.message_id.clone(),
            session_id: message.session_id.clone(),
            sender_actor_id: message.sender_actor_id.clone(),
            kind: match message.kind {
                x if x == teamclaw::MessageKind::Text as i32 => "text",
                x if x == teamclaw::MessageKind::System as i32 => "system",
                x if x == teamclaw::MessageKind::WorkEvent as i32 => "work_event",
                _ => "text",
            }.to_string(),
            content: message.content.clone(),
            created_at: chrono::DateTime::from_timestamp(message.created_at, 0)
                .unwrap_or_else(Utc::now),
            reply_to_message_id: message.reply_to_message_id.clone(),
            mentions: message.mentions.clone(),
        };
        let mut store = MessageStore::load(&self.config_dir, session_id);
        store.append(stored);
        let _ = store.save(&self.config_dir, session_id);
    }

    /// Check if this device hosts the given session.
    pub fn is_host_for(&self, session_id: &str) -> bool {
        self.sessions.find_by_id(session_id)
            .map(|s| s.host_device_id == self.device_id)
            .unwrap_or(false)
    }

    /// Check if an agent should be activated by a message.
    /// Returns the agent actor_ids that should receive this message.
    pub fn agents_to_activate(
        &self,
        session_id: &str,
        message: &teamclaw::Message,
    ) -> Vec<String> {
        let session = match self.sessions.find_by_id(session_id) {
            Some(s) => s,
            None => return Vec::new(),
        };

        let agent_participants: Vec<&StoredParticipant> = session.participants.iter()
            .filter(|p| p.actor_type == "personal_agent" || p.actor_type == "role_agent")
            .collect();

        // If only one agent in session, all messages are relevant
        if agent_participants.len() == 1 {
            return agent_participants.iter().map(|p| p.actor_id.clone()).collect();
        }

        let mut activated = Vec::new();
        for agent in &agent_participants {
            // Check @mentions
            if message.mentions.contains(&agent.actor_id) {
                activated.push(agent.actor_id.clone());
                continue;
            }
        }

        activated
    }

    /// Check if an agent should be activated by a work item event.
    pub fn agents_to_activate_for_work_item(
        &self,
        session_id: &str,
        event: &teamclaw::WorkItemEvent,
    ) -> Vec<String> {
        let work_item_store = WorkItemStore::load(&self.config_dir, session_id);
        let mut activated = Vec::new();

        match &event.event {
            // When a work item is assigned/claimed, activate the claiming agent
            Some(teamclaw::work_item_event::Event::Claimed(claim)) => {
                activated.push(claim.actor_id.clone());
            }
            // When a work item changes, activate agents that have claimed it
            Some(teamclaw::work_item_event::Event::Updated(item)) => {
                for claim in work_item_store.claims_for_item(&item.work_item_id) {
                    activated.push(claim.actor_id.clone());
                }
            }
            Some(teamclaw::work_item_event::Event::Submitted(sub)) => {
                for claim in work_item_store.claims_for_item(&sub.work_item_id) {
                    if claim.actor_id != sub.actor_id {
                        activated.push(claim.actor_id.clone());
                    }
                }
            }
            _ => {}
        }

        activated
    }

    // --- Publishing helpers ---

    async fn publish_session_meta(&self, session_id: &str) {
        if let Some(info) = self.sessions.to_proto_session_info(session_id) {
            let envelope = teamclaw::SessionMetaEnvelope { session: Some(info) };
            let topic = self.topics.session_meta(session_id);
            let _ = self.client.publish(topic, QoS::AtLeastOnce, true, envelope.encode_to_vec()).await;
        }
    }

    async fn publish_session_index(&self) {
        let index = self.sessions.to_proto_index();
        let topic = self.topics.sessions();
        let _ = self.client.publish(topic, QoS::AtLeastOnce, true, index.encode_to_vec()).await;
    }
}
```

- [ ] **Step 2: Update `daemon/src/teamclaw/mod.rs`**

Add:
```rust
pub mod session_manager;
pub use session_manager::SessionManager;
```

- [ ] **Step 3: Verify compilation**

Run: `cd daemon && cargo build 2>&1 | tail -5`
Expected: `Finished` with no errors.

- [ ] **Step 4: Commit**

```bash
git add -f daemon/src/teamclaw/session_manager.rs daemon/src/teamclaw/mod.rs
git commit -m "feat(daemon): add teamclaw session manager

Handles RPC requests for session create/join/fetch, participant
management, work item lifecycle, message persistence, and agent
activation rules. Publishes session metadata and index updates."
```

---

## Task 7: Wire Teamclaw into Daemon Server

**Files:**
- Modify: `daemon/src/daemon/server.rs`
- Modify: `daemon/src/mqtt/client.rs`
- Modify: `daemon/src/mqtt/subscriber.rs`

This task integrates the SessionManager into the existing DaemonServer main loop.

- [ ] **Step 1: Add teamclaw fields to DaemonServer**

In `daemon/src/daemon/server.rs`, add to the `DaemonServer` struct fields (after existing fields):

```rust
    teamclaw: Option<crate::teamclaw::SessionManager>,
```

- [ ] **Step 2: Initialize SessionManager in `DaemonServer::new()`**

After existing initialization code, add:

```rust
        // Initialize teamclaw if team_id is configured
        let teamclaw = if let Some(team_id) = &config.team_id {
            let is_team_host = config.is_team_host.unwrap_or(false);
            Some(crate::teamclaw::SessionManager::new(
                mqtt.client.clone(),
                team_id,
                &config.device.id,
                crate::config::DaemonConfig::config_dir(),
                is_team_host,
            ))
        } else {
            None
        };
```

- [ ] **Step 3: Add `team_id` and `is_team_host` to DaemonConfig**

In `daemon/src/config/daemon_config.rs`, add to the `DaemonConfig` struct:

```rust
    pub team_id: Option<String>,
    pub is_team_host: Option<bool>,
```

- [ ] **Step 4: Subscribe to teamclaw topics in the `run()` method**

In the `run()` method of DaemonServer, after `subscribe_all()` and the initial state publishes, add:

```rust
        if let Some(tc) = &self.teamclaw {
            tc.subscribe_all().await.expect("teamclaw subscribe failed");
        }
```

- [ ] **Step 5: Add teamclaw message parsing to subscriber**

In `daemon/src/mqtt/subscriber.rs`, add a new variant to `IncomingMessage`:

```rust
    TeamclawRpc { topic: String, payload: Vec<u8> },
    TeamclawSessionMessage { session_id: String, payload: Vec<u8> },
    TeamclawWorkItemEvent { session_id: String, payload: Vec<u8> },
```

In `parse_incoming()`, add topic matching for teamclaw topics:

```rust
        // Teamclaw RPC requests
        if topic.starts_with("teamclaw/") && topic.ends_with("/req") {
            return Some(IncomingMessage::TeamclawRpc {
                topic: topic.to_string(),
                payload: publish.payload.to_vec(),
            });
        }
        // Teamclaw session messages
        if topic.starts_with("teamclaw/") && topic.contains("/session/") {
            let parts: Vec<&str> = topic.split('/').collect();
            if parts.len() == 5 {
                let session_id = parts[3].to_string();
                match parts[4] {
                    "messages" => return Some(IncomingMessage::TeamclawSessionMessage {
                        session_id,
                        payload: publish.payload.to_vec(),
                    }),
                    "workitems" => return Some(IncomingMessage::TeamclawWorkItemEvent {
                        session_id,
                        payload: publish.payload.to_vec(),
                    }),
                    _ => {}
                }
            }
        }
```

- [ ] **Step 6: Handle teamclaw messages in the main loop**

In `handle_incoming()` in server.rs, add:

```rust
            IncomingMessage::TeamclawRpc { topic, payload } => {
                if let Some(tc) = &mut self.teamclaw {
                    tc.handle_rpc_request(&topic, &payload).await;
                }
            }
            IncomingMessage::TeamclawSessionMessage { session_id, payload } => {
                if let Some(tc) = &self.teamclaw {
                    // If we're session host, persist the message
                    if tc.is_host_for(&session_id) {
                        if let Ok(envelope) = <crate::proto::teamclaw::SessionMessageEnvelope as prost::Message>::decode(payload.as_slice()) {
                            if let Some(msg) = &envelope.message {
                                tc.persist_message(&session_id, msg);
                            }
                        }
                    }
                }
            }
            IncomingMessage::TeamclawWorkItemEvent { session_id, payload } => {
                // Work item events are handled via RPC; this is for broadcasting
                // No additional action needed on receive for now
            }
```

- [ ] **Step 7: Verify compilation**

Run: `cd daemon && cargo build 2>&1 | tail -5`
Expected: `Finished` with no errors.

- [ ] **Step 8: Commit**

```bash
git add daemon/src/daemon/server.rs daemon/src/mqtt/subscriber.rs daemon/src/config/daemon_config.rs
git commit -m "feat(daemon): wire teamclaw session manager into main loop

Integrates teamclaw into DaemonServer: subscribes to teamclaw MQTT
topics, routes RPC requests to SessionManager, persists messages
for hosted sessions. Activated by team_id in daemon.toml."
```

---

## Task 8: iOS SwiftData Models

**Files:**
- Create: `ios/Packages/AMUXCore/Sources/AMUXCore/Models/CollabSession.swift`
- Create: `ios/Packages/AMUXCore/Sources/AMUXCore/Models/SessionMessage.swift`
- Create: `ios/Packages/AMUXCore/Sources/AMUXCore/Models/WorkItem.swift`
- Modify: `ios/AMUXApp/AMUXApp.swift`

- [ ] **Step 1: Create `CollabSession.swift`**

Follow the pattern in `ios/Packages/AMUXCore/Sources/AMUXCore/Models/Agent.swift` (58 lines).

```swift
import Foundation
import SwiftData

@Model
public final class CollabSession {
    @Attribute(.unique) public var sessionId: String
    public var sessionType: String       // "control" or "collab"
    public var teamId: String
    public var title: String
    public var hostDeviceId: String
    public var createdBy: String
    public var createdAt: Date
    public var summary: String
    public var participantCount: Int
    public var lastMessagePreview: String
    public var lastMessageAt: Date?

    public init(
        sessionId: String,
        sessionType: String = "collab",
        teamId: String = "",
        title: String = "",
        hostDeviceId: String = "",
        createdBy: String = "",
        createdAt: Date = .now,
        summary: String = "",
        participantCount: Int = 0,
        lastMessagePreview: String = "",
        lastMessageAt: Date? = nil
    ) {
        self.sessionId = sessionId
        self.sessionType = sessionType
        self.teamId = teamId
        self.title = title
        self.hostDeviceId = hostDeviceId
        self.createdBy = createdBy
        self.createdAt = createdAt
        self.summary = summary
        self.participantCount = participantCount
        self.lastMessagePreview = lastMessagePreview
        self.lastMessageAt = lastMessageAt
    }

    public var isCollab: Bool { sessionType == "collab" }
    public var isControl: Bool { sessionType == "control" }
}
```

- [ ] **Step 2: Create `SessionMessage.swift`**

```swift
import Foundation
import SwiftData

@Model
public final class SessionMessage {
    @Attribute(.unique) public var messageId: String
    public var sessionId: String
    public var senderActorId: String
    public var kind: String             // "text", "system", "work_event"
    public var content: String
    public var createdAt: Date
    public var replyToMessageId: String
    public var mentions: String         // comma-separated actor IDs (SwiftData workaround for [String])

    public init(
        messageId: String,
        sessionId: String = "",
        senderActorId: String = "",
        kind: String = "text",
        content: String = "",
        createdAt: Date = .now,
        replyToMessageId: String = "",
        mentions: String = ""
    ) {
        self.messageId = messageId
        self.sessionId = sessionId
        self.senderActorId = senderActorId
        self.kind = kind
        self.content = content
        self.createdAt = createdAt
        self.replyToMessageId = replyToMessageId
        self.mentions = mentions
    }

    public var isSystem: Bool { kind == "system" }
    public var isText: Bool { kind == "text" }
    public var mentionList: [String] {
        mentions.isEmpty ? [] : mentions.split(separator: ",").map(String.init)
    }
}
```

- [ ] **Step 3: Create `WorkItem.swift`**

```swift
import Foundation
import SwiftData

@Model
public final class WorkItem {
    @Attribute(.unique) public var workItemId: String
    public var sessionId: String
    public var title: String
    public var itemDescription: String  // "description" is reserved
    public var status: String           // "open", "in_progress", "done"
    public var parentId: String
    public var createdBy: String
    public var createdAt: Date

    public init(
        workItemId: String,
        sessionId: String = "",
        title: String = "",
        itemDescription: String = "",
        status: String = "open",
        parentId: String = "",
        createdBy: String = "",
        createdAt: Date = .now
    ) {
        self.workItemId = workItemId
        self.sessionId = sessionId
        self.title = title
        self.itemDescription = itemDescription
        self.status = status
        self.parentId = parentId
        self.createdBy = createdBy
        self.createdAt = createdAt
    }

    public var isOpen: Bool { status == "open" }
    public var isInProgress: Bool { status == "in_progress" }
    public var isDone: Bool { status == "done" }

    public var statusLabel: String {
        switch status {
        case "open": return "Open"
        case "in_progress": return "In Progress"
        case "done": return "Done"
        default: return status
        }
    }
}
```

- [ ] **Step 4: Register new models in `AMUXApp.swift`**

In `ios/AMUXApp/AMUXApp.swift`, add the new types to the model container:

Change:
```swift
.modelContainer(for: [Agent.self, AgentEvent.self, Member.self, Workspace.self])
```
To:
```swift
.modelContainer(for: [Agent.self, AgentEvent.self, Member.self, Workspace.self, CollabSession.self, SessionMessage.self, WorkItem.self])
```

- [ ] **Step 5: Verify Xcode builds**

Open `ios/AMUX.xcodeproj` in Xcode and build (Cmd+B). All new models should compile and be registered with SwiftData.

- [ ] **Step 6: Commit**

```bash
git add ios/Packages/AMUXCore/Sources/AMUXCore/Models/CollabSession.swift ios/Packages/AMUXCore/Sources/AMUXCore/Models/SessionMessage.swift ios/Packages/AMUXCore/Sources/AMUXCore/Models/WorkItem.swift ios/AMUXApp/AMUXApp.swift
git commit -m "feat(ios): add SwiftData models for teamclaw collaboration

CollabSession (control/collab), SessionMessage, and WorkItem models.
Registered in the app's model container."
```

---

## Task 9: iOS TeamclawService (MQTT Subscriptions + RPC Client)

**Files:**
- Create: `ios/Packages/AMUXCore/Sources/AMUXCore/TeamclawService.swift`

- [ ] **Step 1: Create `TeamclawService.swift`**

This service manages teamclaw MQTT subscriptions and provides RPC methods. Follow the pattern in `MQTTService.swift` and `SessionListViewModel.swift`.

```swift
import Foundation
import SwiftProtobuf
import SwiftData

@Observable
@MainActor
public final class TeamclawService {
    public var sessions: [CollabSession] = []
    public var isConnected = false

    private var mqtt: MQTTService?
    private var teamId: String = ""
    private var deviceId: String = ""
    private var peerId: String = ""
    private var listenerTask: Task<Void, Never>?

    public init() {}

    public func start(
        mqtt: MQTTService,
        teamId: String,
        deviceId: String,
        peerId: String,
        modelContext: ModelContext
    ) {
        self.mqtt = mqtt
        self.teamId = teamId
        self.deviceId = deviceId
        self.peerId = peerId

        listenerTask?.cancel()
        listenerTask = Task { [weak self] in
            guard let self, let mqtt = self.mqtt else { return }

            // Subscribe to team-level topics
            mqtt.subscribe("teamclaw/\(teamId)/sessions")
            mqtt.subscribe("teamclaw/\(teamId)/members")
            mqtt.subscribe("teamclaw/\(teamId)/user/\(peerId)/invites")

            // Subscribe to RPC responses for this device
            mqtt.subscribe("teamclaw/\(teamId)/rpc/\(deviceId)/+/res")

            for await incoming in mqtt.messages() {
                guard !Task.isCancelled else { break }
                await self.handleIncoming(incoming, modelContext: modelContext)
            }
        }
    }

    public func stop() {
        listenerTask?.cancel()
        listenerTask = nil
    }

    private func handleIncoming(_ incoming: MQTTIncoming, modelContext: ModelContext) async {
        let topic = incoming.topic

        // Session index
        if topic == "teamclaw/\(teamId)/sessions" {
            if let index = try? Teamclaw_SessionIndex(serializedBytes: incoming.payload) {
                syncSessionIndex(index, modelContext: modelContext)
            }
            return
        }

        // Session messages
        if topic.contains("/session/") && topic.hasSuffix("/messages") {
            if let envelope = try? Teamclaw_SessionMessageEnvelope(serializedBytes: incoming.payload),
               envelope.hasMessage {
                syncMessage(envelope.message, modelContext: modelContext)
            }
            return
        }

        // Invites
        if topic.hasSuffix("/invites") {
            if let envelope = try? Teamclaw_InviteEnvelope(serializedBytes: incoming.payload),
               envelope.hasInvite {
                handleInvite(envelope.invite)
            }
            return
        }

        // Work item events
        if topic.contains("/session/") && topic.hasSuffix("/workitems") {
            if let event = try? Teamclaw_WorkItemEvent(serializedBytes: incoming.payload) {
                syncWorkItemEvent(event, modelContext: modelContext)
            }
            return
        }
    }

    private func syncSessionIndex(_ index: Teamclaw_SessionIndex, modelContext: ModelContext) {
        for entry in index.sessions {
            let descriptor = FetchDescriptor<CollabSession>(
                predicate: #Predicate { $0.sessionId == entry.sessionID }
            )
            let existing = (try? modelContext.fetch(descriptor))?.first

            if let session = existing {
                session.title = entry.title
                session.participantCount = Int(entry.participantCount)
                session.lastMessagePreview = entry.lastMessagePreview
                if entry.lastMessageAt > 0 {
                    session.lastMessageAt = Date(timeIntervalSince1970: TimeInterval(entry.lastMessageAt))
                }
            } else {
                let session = CollabSession(
                    sessionId: entry.sessionID,
                    sessionType: entry.sessionType == .control ? "control" : "collab",
                    title: entry.title,
                    hostDeviceId: entry.hostDeviceID,
                    createdAt: Date(timeIntervalSince1970: TimeInterval(entry.createdAt)),
                    participantCount: Int(entry.participantCount),
                    lastMessagePreview: entry.lastMessagePreview
                )
                modelContext.insert(session)
            }
        }
        try? modelContext.save()
    }

    private func syncMessage(_ message: Teamclaw_Message, modelContext: ModelContext) {
        let descriptor = FetchDescriptor<SessionMessage>(
            predicate: #Predicate { $0.messageId == message.messageID }
        )
        guard (try? modelContext.fetch(descriptor))?.first == nil else { return }

        let msg = SessionMessage(
            messageId: message.messageID,
            sessionId: message.sessionID,
            senderActorId: message.senderActorID,
            kind: {
                switch message.kind {
                case .text: return "text"
                case .system: return "system"
                case .workEvent: return "work_event"
                default: return "text"
                }
            }(),
            content: message.content,
            createdAt: Date(timeIntervalSince1970: TimeInterval(message.createdAt)),
            replyToMessageId: message.replyToMessageID,
            mentions: message.mentions.joined(separator: ",")
        )
        modelContext.insert(msg)
        try? modelContext.save()
    }

    private func handleInvite(_ invite: Teamclaw_Invite) {
        // Subscribe to the invited session's topics
        guard let mqtt else { return }
        let sid = invite.sessionID
        mqtt.subscribe("teamclaw/\(teamId)/session/\(sid)/messages")
        mqtt.subscribe("teamclaw/\(teamId)/session/\(sid)/meta")
        mqtt.subscribe("teamclaw/\(teamId)/session/\(sid)/workitems")
        mqtt.subscribe("teamclaw/\(teamId)/session/\(sid)/presence")
    }

    private func syncWorkItemEvent(_ event: Teamclaw_WorkItemEvent, modelContext: ModelContext) {
        let item: Teamclaw_WorkItem? = {
            switch event.event {
            case .created(let wi): return wi
            case .updated(let wi): return wi
            default: return nil
            }
        }()

        guard let item else { return }

        let descriptor = FetchDescriptor<WorkItem>(
            predicate: #Predicate { $0.workItemId == item.workItemID }
        )
        let existing = (try? modelContext.fetch(descriptor))?.first

        if let wi = existing {
            wi.title = item.title
            wi.itemDescription = item.description_p
            wi.status = {
                switch item.status {
                case .open: return "open"
                case .inProgress: return "in_progress"
                case .done: return "done"
                default: return "open"
                }
            }()
        } else {
            let wi = WorkItem(
                workItemId: item.workItemID,
                sessionId: item.sessionID,
                title: item.title,
                itemDescription: item.description_p,
                status: {
                    switch item.status {
                    case .open: return "open"
                    case .inProgress: return "in_progress"
                    case .done: return "done"
                    default: return "open"
                    }
                }(),
                parentId: item.parentID,
                createdBy: item.createdBy,
                createdAt: Date(timeIntervalSince1970: TimeInterval(item.createdAt))
            )
            modelContext.insert(wi)
        }
        try? modelContext.save()
    }

    // --- RPC Methods ---

    public func sendMessage(sessionId: String, content: String, actorId: String) {
        guard let mqtt else { return }
        var msg = Teamclaw_Message()
        msg.messageID = UUID().uuidString.prefix(8).lowercased()
        msg.sessionID = sessionId
        msg.senderActorID = actorId
        msg.kind = .text
        msg.content = content
        msg.createdAt = Int64(Date().timeIntervalSince1970)

        var envelope = Teamclaw_SessionMessageEnvelope()
        envelope.message = msg

        let topic = "teamclaw/\(teamId)/session/\(sessionId)/messages"
        if let data = try? envelope.serializedData() {
            mqtt.publish(topic: topic, payload: data, retain: false)
        }
    }

    public func subscribeToSession(_ sessionId: String) {
        guard let mqtt else { return }
        mqtt.subscribe("teamclaw/\(teamId)/session/\(sessionId)/messages")
        mqtt.subscribe("teamclaw/\(teamId)/session/\(sessionId)/meta")
        mqtt.subscribe("teamclaw/\(teamId)/session/\(sessionId)/workitems")
        mqtt.subscribe("teamclaw/\(teamId)/session/\(sessionId)/presence")
    }
}
```

- [ ] **Step 2: Verify Xcode builds**

Open Xcode, build the AMUXCore target.

- [ ] **Step 3: Commit**

```bash
git add ios/Packages/AMUXCore/Sources/AMUXCore/TeamclawService.swift
git commit -m "feat(ios): add TeamclawService for MQTT subscriptions and RPC

Manages teamclaw topic subscriptions, syncs session index and messages
to SwiftData, handles invites, provides sendMessage RPC method."
```

---

## Task 10: iOS Collab Session View

**Files:**
- Create: `ios/Packages/AMUXUI/Sources/AMUXUI/Collab/CollabSessionView.swift`
- Create: `ios/Packages/AMUXUI/Sources/AMUXUI/Collab/CollabSessionViewModel.swift`
- Modify: `ios/Packages/AMUXUI/Sources/AMUXUI/SessionList/SessionListView.swift`
- Modify: `ios/AMUXApp/ContentView.swift`

- [ ] **Step 1: Create `CollabSessionViewModel.swift`**

Follow the pattern in `AgentDetailViewModel.swift` (212 lines).

```swift
import Foundation
import SwiftData
import AMUXCore

@Observable
@MainActor
public final class CollabSessionViewModel {
    public var messages: [SessionMessage] = []
    public var workItems: [WorkItem] = []
    public var session: CollabSession

    private var teamclawService: TeamclawService?
    private var listenerTask: Task<Void, Never>?
    private var actorId: String = ""

    public init(session: CollabSession) {
        self.session = session
    }

    public func start(
        teamclawService: TeamclawService,
        actorId: String,
        modelContext: ModelContext
    ) {
        self.teamclawService = teamclawService
        self.actorId = actorId

        teamclawService.subscribeToSession(session.sessionId)

        listenerTask?.cancel()
        listenerTask = Task { [weak self] in
            guard let self else { return }
            // Poll SwiftData for messages in this session
            while !Task.isCancelled {
                let sid = self.session.sessionId
                let msgDescriptor = FetchDescriptor<SessionMessage>(
                    predicate: #Predicate { $0.sessionId == sid },
                    sortBy: [SortDescriptor(\.createdAt)]
                )
                self.messages = (try? modelContext.fetch(msgDescriptor)) ?? []

                let wiDescriptor = FetchDescriptor<WorkItem>(
                    predicate: #Predicate { $0.sessionId == sid },
                    sortBy: [SortDescriptor(\.createdAt)]
                )
                self.workItems = (try? modelContext.fetch(wiDescriptor)) ?? []

                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    public func stop() {
        listenerTask?.cancel()
        listenerTask = nil
    }

    public func sendMessage(_ text: String) {
        teamclawService?.sendMessage(
            sessionId: session.sessionId,
            content: text,
            actorId: actorId
        )
    }
}
```

- [ ] **Step 2: Create `CollabSessionView.swift`**

Follow the layout pattern in `AgentDetailView.swift` (336 lines) — ScrollView of messages with a bottom input bar.

```swift
import SwiftUI
import SwiftData
import AMUXCore

public struct CollabSessionView: View {
    let session: CollabSession
    let teamclawService: TeamclawService
    let actorId: String

    @Environment(\.modelContext) private var modelContext
    @State private var viewModel: CollabSessionViewModel
    @State private var promptText = ""

    public init(session: CollabSession, teamclawService: TeamclawService, actorId: String) {
        self.session = session
        self.teamclawService = teamclawService
        self.actorId = actorId
        self._viewModel = State(initialValue: CollabSessionViewModel(session: session))
    }

    public var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(viewModel.messages, id: \.messageId) { message in
                            CollabMessageBubble(message: message, isMe: message.senderActorId == actorId)
                                .id(message.messageId)
                        }
                    }
                    .padding()
                }
                .onChange(of: viewModel.messages.count) {
                    if let last = viewModel.messages.last {
                        withAnimation {
                            proxy.scrollTo(last.messageId, anchor: .bottom)
                        }
                    }
                }
            }

            // Work items summary bar
            if !viewModel.workItems.isEmpty {
                workItemBar
            }

            // Input bar
            HStack(spacing: 8) {
                TextField("Message...", text: $promptText, axis: .vertical)
                    .lineLimit(1...5)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))

                Button {
                    guard !promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                    viewModel.sendMessage(promptText)
                    promptText = ""
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                }
                .disabled(promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .navigationTitle(session.title.isEmpty ? "Collab Session" : session.title)
        .task {
            viewModel.start(
                teamclawService: teamclawService,
                actorId: actorId,
                modelContext: modelContext
            )
        }
        .onDisappear {
            viewModel.stop()
        }
    }

    private var workItemBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(viewModel.workItems, id: \.workItemId) { item in
                    HStack(spacing: 4) {
                        Circle()
                            .fill(item.isDone ? .green : item.isInProgress ? .orange : .blue)
                            .frame(width: 8, height: 8)
                        Text(item.title)
                            .font(.caption)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.ultraThinMaterial, in: Capsule())
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
        }
    }
}

struct CollabMessageBubble: View {
    let message: SessionMessage
    let isMe: Bool

    var body: some View {
        HStack {
            if isMe { Spacer(minLength: 60) }

            VStack(alignment: isMe ? .trailing : .leading, spacing: 2) {
                if !isMe {
                    Text(message.senderActorId)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(message.content)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        message.isSystem ? Color.yellow.opacity(0.15) :
                        isMe ? Color.blue.opacity(0.15) : Color(.systemGray5),
                        in: RoundedRectangle(cornerRadius: 16)
                    )
                    .font(message.isSystem ? .callout.italic() : .body)
            }

            if !isMe { Spacer(minLength: 60) }
        }
    }
}
```

- [ ] **Step 3: Add collab sessions to SessionListView navigation**

In `ios/Packages/AMUXUI/Sources/AMUXUI/SessionList/SessionListView.swift`, add a navigation destination for `CollabSession`. In the `NavigationStack`, add:

```swift
.navigationDestination(for: String.self) { sessionId in
    // Existing agent detail navigation stays
    // ...
}
```

The exact integration depends on how the current navigation stack is wired — the implementing engineer should add a section in the session list that shows collab sessions from `TeamclawService.sessions` alongside the existing agent sessions, and wire up navigation to `CollabSessionView`.

- [ ] **Step 4: Initialize TeamclawService in ContentView**

In `ios/AMUXApp/ContentView.swift`, add:

```swift
@State private var teamclawService = TeamclawService()
```

After successful MQTT connection (where `connectionMonitor.start()` is called), add:

```swift
teamclawService.start(
    mqtt: mqtt,
    teamId: pairing.teamId,  // needs to be added to PairingManager
    deviceId: pairing.deviceId,
    peerId: "ios-\(pairing.authToken.prefix(6))",
    modelContext: modelContext
)
```

Note: `PairingManager` needs a `teamId` field. Add it to `PairingManager.swift` following the same pattern as `deviceId` — stored in UserDefaults, parsed from the pairing URL.

- [ ] **Step 5: Verify Xcode builds**

Build in Xcode. The collab session views should compile and be navigable.

- [ ] **Step 6: Commit**

```bash
git add ios/Packages/AMUXUI/Sources/AMUXUI/Collab/ ios/AMUXApp/ContentView.swift
git commit -m "feat(ios): add collab session view and wire TeamclawService

CollabSessionView with message list, work item bar, and input.
TeamclawService initialized on app launch when team_id is configured."
```

---

## Task 11: End-to-End Validation

**Files:** No new files. This task validates the full flow.

- [ ] **Step 1: Configure two test amuxd instances**

Add to `~/.config/amux/daemon.toml` on machine A:
```toml
team_id = "test-team"
is_team_host = true
```

Add to `~/.config/amux/daemon.toml` on machine B:
```toml
team_id = "test-team"
is_team_host = false
```

- [ ] **Step 2: Start both daemons**

On machine A: `cd daemon && RUST_LOG=amuxd=debug cargo run -- start`
On machine B: `cd daemon && RUST_LOG=amuxd=debug cargo run -- start`

Verify both connect to MQTT and subscribe to teamclaw topics (check debug logs).

- [ ] **Step 3: Test session creation via MQTT RPC**

Use `test-client` or a manual MQTT publish to send a `CreateSessionRequest` RPC to machine A. Verify:
- Session metadata published to `teamclaw/test-team/session/{id}/meta`
- Session index updated at `teamclaw/test-team/sessions`
- Invite published if `invite_actor_ids` was set

- [ ] **Step 4: Test message flow**

Publish a `SessionMessageEnvelope` to `teamclaw/test-team/session/{id}/messages`. Verify:
- Machine A (host) persists the message to `~/.config/amux/teamclaw/sessions/{id}/messages.toml`
- Other subscribers receive the message

- [ ] **Step 5: Test iOS client**

Launch iOS app, pair with machine A. Verify:
- Session list shows collab sessions from the session index
- Tapping a collab session shows the chat view
- Sending a message publishes to the correct topic and appears for all participants

- [ ] **Step 6: Test work item flow**

Send a `CreateWorkItemRequest` RPC. Then `ClaimWorkItemRequest`. Then `SubmitWorkItemRequest`. Verify:
- Work items appear in the collab session view
- Status transitions are persisted and broadcast

- [ ] **Step 7: Commit any test fixes**

```bash
git add -A
git commit -m "fix: address issues found during e2e validation"
```

---

## Dependency Order

```
Task 1 (Proto) ──┬── Task 2 (Topics) ── Task 5 (RPC) ──┐
                  │                                       │
                  ├── Task 3 (Session Store) ─────────────┤
                  │                                       │
                  ├── Task 4 (Message/WorkItem Store) ────┼── Task 6 (Session Manager) ── Task 7 (Wire into Server)
                  │                                       │
                  ├── Task 8 (iOS Models) ────────────────┤
                  │                                       │
                  └── Task 9 (iOS TeamclawService) ───────┴── Task 10 (iOS Collab View) ── Task 11 (Validation)
```

- Tasks 2, 3, 4, 8 can run in parallel after Task 1
- Task 5 depends on Task 2
- Task 6 depends on Tasks 2, 3, 4, 5
- Task 7 depends on Task 6
- Task 9 depends on Tasks 1, 8
- Task 10 depends on Task 9
- Task 11 depends on Tasks 7, 10
