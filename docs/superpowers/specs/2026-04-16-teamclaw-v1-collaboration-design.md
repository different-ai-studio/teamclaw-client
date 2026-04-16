# Teamclaw V1 Collaboration Layer — Design Spec

## Problem

Small teams (3-10 people) already use multiple AI agents — personal desktop agents, shared role agents, ChatGPT, Claude Code. But these agents are isolated: each is a private tool controlled by one person. Collaboration happens through copy-paste, screenshots, and verbal relay. The result is "human-routed agents" — people manually shuttle context between their private agent chats and team group discussions.

## Product Definition

Teamclaw v1 is a collaboration layer on top of AMUX (agent runtime). It lets a small team put humans, personal agents, and shared role agents into the same session to work together on a problem — while preserving each person's private control channel with their own agent.

It is not an autonomous agent network. It is not a Slack replacement. It is a system that turns agents from "personal plugins" into "team members with private context and permission boundaries."

## V1 Scope

**In scope:**
- One team, one workflow: cross-functional problem where a lead kicks off a task, multiple agents and a few humans collaborate, results get submitted
- Two session types: control + collab
- Three actor types: human, personal_agent, role_agent
- Work items as session-owned objects
- MQTT-only communication (no HTTP direct connect)

**Out of scope:**
- Standalone cloud control plane / Postgres
- Multi-team or multi-tenant
- Distributed metadata consensus
- Separate work/subtask session types
- Knowledge board / debate board / autonomous orchestration
- Full Slack/Feishu replacement
- Host migration or failover

---

## System Architecture

### Deployment Topology

```
iOS/Mac Client A          iOS/Mac Client B
       |                         |
       +---- MQTT Broker (TLS) --+
                   |
            +------+------+
            |             |
         amuxd A       amuxd B
         (team host)   (participant)
```

- No standalone Control Plane
- No HTTPS direct connect between client and amuxd
- All communication (realtime messages, metadata fetch, state sync) goes through MQTT
- amuxd stores metadata locally; MQTT is transport only, not source of truth

### Layer Responsibilities

**AMUX / amuxd:**
- Agent runtime (spawn, manage, stop agent processes)
- Local metadata store (sessions, members, work items, messages)
- MQTT request/reply handlers for metadata fetch and mutation
- Session hosting (source of truth for sessions it hosts)

**MQTT Broker:**
- Realtime message delivery
- Invite delivery
- Presence and state events
- Request/reply transport for metadata operations

**Client:**
- Session list (control + collab)
- Realtime chat within sessions
- Work item display and interaction
- Local cache of metadata from host amuxd

---

## Core Model

### Actor Types

| Type | Description | Runtime | Visibility |
|---|---|---|---|
| `human` | Real person using a client | N/A | Visible to team |
| `personal_agent` | A person's private agent | Owner's amuxd | Private by default; visible in collab sessions it joins |
| `role_agent` | Team-shared agent (e.g. "dev agent", "marketing agent") | Fixed host amuxd, configured by team owner | Visible to all members with permission |

**Role agent hosting rule (v1):** Each role agent runs on a fixed amuxd designated by the team owner. No migration in v1. If that amuxd goes offline, the role agent is unavailable.

### Session Types

| Type | Participants | Host | Visibility |
|---|---|---|---|
| `control` | One human + that human's personal agent | Owner's amuxd | Owner only |
| `collab` | Multiple humans and/or agents | Creator's amuxd | All participants |

**Session rules:**
- A human can have multiple control sessions (one per topic/conversation)
- control sessions are private; cannot directly add other participants
- Inviting others from a control session creates a new collab session with a handoff summary
- collab sessions can add/remove participants directly
- A collab session may contain any mix of humans, personal agents, and role agents

### Host Model

Three distinct host roles, all must be explicitly defined:

| Host Role | What It Hosts | Determined By |
|---|---|---|
| **Team host** | Team member directory (source of truth) | Team creator's amuxd |
| **Session host** | One collab session's metadata, messages, work items | Session creator's amuxd |
| **Role agent host** | One role agent's runtime process | Configured by team owner |

**Failure behavior (v1):**
- Team host offline → member list updates blocked; cached copies still readable
- Session host offline → session metadata and new messages unavailable; cached state still viewable
- Role agent host offline → role agent unavailable

### Message

The fundamental unit of communication within a session.

| Field | Type | Description |
|---|---|---|
| `message_id` | string | Unique identifier |
| `session_id` | string | Which session this belongs to |
| `sender_actor_id` | string | Who sent it (human or agent) |
| `kind` | enum | `text`, `system`, `work_event` |
| `content` | string | Message body |
| `created_at` | timestamp | When it was sent |
| `reply_to_message_id` | string? | Optional thread/reply reference |
| `mentions` | string[] | Actor IDs mentioned in this message |

**Storage rules:**
- Session host amuxd stores full message history for sessions it hosts
- Participant clients cache recent messages locally
- New participants joining a collab session receive: session summary + new messages from join point
- V1 does not expose full history to late joiners

### WorkItem

A lightweight task card attached to a collab session.

| Field | Type | Description |
|---|---|---|
| `work_item_id` | string | Unique identifier |
| `session_id` | string | Owning collab session |
| `title` | string | Short description |
| `description` | string | Details |
| `status` | enum | `open`, `in_progress`, `done` |
| `parent_id` | string? | Parent work item (for subtasks) |
| `created_by` | string | Actor who created it |
| `created_at` | timestamp | When it was created |

### Claim

Records that an actor picked up a work item.

| Field | Type | Description |
|---|---|---|
| `claim_id` | string | Unique identifier |
| `work_item_id` | string | Which work item |
| `actor_id` | string | Who claimed it |
| `claimed_at` | timestamp | When |

### Submission

Records that an actor submitted a result for a work item.

| Field | Type | Description |
|---|---|---|
| `submission_id` | string | Unique identifier |
| `work_item_id` | string | Which work item |
| `actor_id` | string | Who submitted |
| `content` | string | Result content |
| `submitted_at` | timestamp | When |

---

## Personal Agent Rules

- Personal agents are private by default
- Other users do not see another member's personal agent in the global directory
- A user may bring their own personal agent into a collab session
- Once inside a collab session, other participants may: see, mention, chat with, assign work items to the agent
- Other participants may NOT: control, manage, reconfigure, or take over the agent
- The agent remains running on its owner's amuxd regardless of which session it participates in

---

## Agent Participation Mechanism

Agents do not directly subscribe to MQTT session topics. The routing path is:

```
Collab message → session MQTT topic → owner's amuxd → agent process
Agent reply → owner's amuxd → session MQTT topic → all participants
```

**How it works:**
1. amuxd subscribes to session topics for sessions where its agents participate
2. When a relevant message arrives (mentions the agent, or is a direct message), amuxd forwards it to the local agent process
3. Agent produces a response through the normal ACP event stream
4. amuxd wraps the response and publishes it back to the session topic

**Context provided to agents (v1):**
- Session summary
- Last N messages (configurable, reasonable default)
- Messages that explicitly @mention the agent
- Not full session history

---

## Context Handoff

When forking a control session into a collab session:

1. The system generates or the user writes a **handoff summary** — a short description of what was discussed privately and what the collab session should focus on
2. This summary becomes the first message (kind: `system`) in the new collab session
3. The full control session history is NOT copied into the collab session

Two sources for the summary (v1):
- **User-written:** User types a summary before creating the collab session
- **System-generated:** amuxd asks the agent to summarize the control session conversation

---

## MQTT Topic Structure

AMUX runtime topics and Teamclaw collaboration topics use separate namespaces.

### Existing AMUX Namespace (unchanged)

```
amux/{deviceId}/agents
amux/{deviceId}/agent/{agentId}/events
amux/{deviceId}/agent/{agentId}/commands
amux/{deviceId}/status
```

### Teamclaw Namespace (new)

```
# Team-level
teamclaw/{teamId}/members                         # MemberList (retained)
teamclaw/{teamId}/sessions                         # SessionList summary (retained)

# Session-level
teamclaw/{teamId}/session/{sessionId}/messages     # Message stream (QoS 1)
teamclaw/{teamId}/session/{sessionId}/meta         # Session metadata (retained)
teamclaw/{teamId}/session/{sessionId}/presence     # Participant presence (retained)
teamclaw/{teamId}/session/{sessionId}/workitems    # WorkItem updates (QoS 1)

# User-level
teamclaw/{teamId}/user/{userId}/invites            # Invite delivery (QoS 1)

# Request/reply (metadata fetch)
teamclaw/{teamId}/rpc/{requestId}/req              # Request
teamclaw/{teamId}/rpc/{requestId}/res              # Response
```

**Rule:** Runtime topics stay device/agent-oriented. Collaboration topics are session-oriented.

---

## Main Flows

### Flow 1: Private discussion becomes collaboration

1. User chats with their personal agent in a `control` session
2. User decides to involve others
3. User writes a handoff summary (or requests system-generated summary)
4. System creates a new `collab` session on the user's amuxd (which becomes session host)
5. Handoff summary becomes the first system message in the collab session
6. Host publishes invite to `teamclaw/{teamId}/user/{inviteeId}/invites`
7. Invitee's client receives invite, sends RPC to host amuxd to fetch session metadata
8. Invitee subscribes to the session's MQTT topics

### Flow 2: Direct group collaboration

1. User creates a `collab` session directly (their amuxd becomes host)
2. User invites teammates and/or agents
3. Invitees fetch metadata via MQTT RPC and subscribe to session topics
4. All messaging flows through `teamclaw/{teamId}/session/{sessionId}/messages`

### Flow 3: Bringing a personal agent into a collab session

1. User is participating in a collab session
2. User adds their personal agent to the session
3. User's amuxd subscribes to the session topic on behalf of the agent
4. amuxd forwards relevant messages to the agent process
5. Agent replies flow back through amuxd to the session topic
6. Other participants see the agent's messages in the session

### Flow 4: Work item lifecycle

1. A participant creates a WorkItem inside a collab session
2. Host amuxd stores it; publishes update to workitems topic
3. One or more actors create Claims (host records and broadcasts)
4. Actors work and discuss in the same collab session
5. Actors submit Submissions (host records and broadcasts)
6. Optional: child work items created via `parent_id`

---

## Implementation Phases

### Phase 1: Core data model

- Add Teamclaw metadata types to daemon storage: Session (control/collab), Message, WorkItem, Claim, Submission
- Add team host concept and member directory store
- Add session host metadata and participant tracking
- Add role agent host configuration

### Phase 2: MQTT protocol

- Add Teamclaw MQTT topic helpers (separate namespace)
- Add message publish/subscribe for session topics
- Add MQTT RPC request/reply handlers for metadata fetch
- Add invite message type and delivery
- Add presence event publishing

### Phase 3: Session lifecycle in amuxd

- MQTT request handlers: create session, join session, fetch metadata
- MQTT request handlers: add/remove participants
- MQTT request handlers: create/update work items, claims, submissions
- Agent routing: forward session messages to local agent processes
- Agent routing: publish agent replies back to session topics
- Context handoff: generate or accept summary when forking control → collab

### Phase 4: Protobuf schema

- Add Teamclaw message types to proto/amux.proto (or new proto/teamclaw.proto)
- Define: Session, Message, WorkItem, Claim, Submission, Invite, HandoffSummary
- Define: RPC request/response wrappers
- Regenerate Rust and Swift code

### Phase 5: Client integration

- Show control and collab sessions in session list
- Support "invite into collab" from a control session
- Subscribe to Teamclaw session topics over MQTT
- Cache session metadata locally
- Display messages in session chat view
- Show work items, claims, submissions inside collab sessions
- Handle invites (receive, accept, fetch metadata)

### Phase 6: Validation

- Validate one cross-functional workflow with a real team
- Validate control → collab handoff with summary
- Validate bringing a personal agent into a shared session
- Validate role agent participation in a collab session
- Validate parallel claims and multiple submissions for a work item

---

## Exit Criteria

V1 is successful when all of the following are true:

- A user can keep multiple private control sessions with their personal agent
- A user can fork a private control discussion into a shared collab session with a handoff summary
- Another human on a different amuxd can join a collab session
- A participant can bring their own personal agent into a shared collab session; other participants can mention and assign work to it but cannot control it
- A role agent hosted on a designated amuxd can participate in a collab session
- Messages flow in realtime through MQTT between all session participants
- A work item can be created, claimed by multiple actors, and receive multiple submissions
- All communication uses MQTT (no HTTP direct connect)
- The flow works for one real team workflow
