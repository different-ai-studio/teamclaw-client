# Session Resume Design

**Date:** 2026-04-18
**Status:** Approved

## Problem

When `amuxd` restarts, all in-memory `AgentHandle` entries are lost. The iOS client still shows historical sessions (via `SessionStore` → `merged_agent_list`), but sending a prompt to one fails with "agent not found" because there is no live ACP process backing it.

## Solution

Lazy resume via ACP `resume_session` (unstable). When a `SendPrompt` targets a non-live agent that exists in `SessionStore`, the daemon transparently spawns a new ACP process, resumes the session, and forwards the prompt. Falls back to `new_session` if the resume fails (e.g. session expired).

## Design

### 1. Persistence: ACP Session ID

**`StoredSession`** gains a new field:

```rust
pub acp_session_id: String,
```

This is the `session_id` returned by ACP `new_session` or `resume_session` — distinct from the amux `agent_id` (8-char UUID).

**`AgentHandle`** also gains `acp_session_id: String` so the running agent tracks its current ACP session.

The adapter bubbles the ACP `session_id` back to `AgentManager` via a new oneshot channel (same pattern as the existing `initial_model_tx`). On every spawn (new or resume), the server persists `acp_session_id` into `sessions.toml`.

### 2. Adapter: Resume vs New Session

`spawn_acp_agent` gains an `Option<String>` parameter (`resume_acp_session_id`):

- `None` → call `new_session(cwd)` as today
- `Some(id)` → call `resume_session(id, cwd)`; on failure, log a warning and fall back to `new_session(cwd)`

The rest of the adapter flow (event loop, command channel, model setting, prompt sending) is identical in both paths. The `acp_session_id` (whichever was used) is sent back via the oneshot channel.

### 3. AgentManager: `resume_agent`

New method `resume_agent(agent_id, acp_session_id, agent_type, worktree, workspace_id, prompt)`:

- Creates an `AgentHandle` with the **existing** `agent_id` (not a new UUID)
- Calls `spawn_acp_agent` with `resume_acp_session_id = Some(acp_session_id)`
- Inserts the handle into `agents` HashMap
- Returns the (possibly new) `acp_session_id` for persistence

### 4. Server: Lazy Resume on SendPrompt

The `SendPrompt` handler in `server.rs` changes from:

```
agent not in AgentManager → error "agent not found"
```

to:

```
agent not in AgentManager
  → look up SessionStore by agent_id
  → found: call agents.resume_agent(...)
    → update StoredSession with new acp_session_id if changed
    → forward the prompt
  → not found: error "agent not found"
```

### 5. Cargo.toml

```toml
agent-client-protocol = {
  version = "0.10.4",
  features = ["unstable_session_model", "unstable_session_resume"]
}
```

### 6. iOS: No Changes

The iOS client already displays historical sessions and allows sending prompts. The daemon handles resume transparently. Status updates flow through the normal ACP event → MQTT pipeline.

The only user-visible difference: a brief delay on the first prompt to a disconnected session while the ACP subprocess spawns.

## Fallback Behavior

If `resume_session` fails (session garbage-collected, ACP agent doesn't support resume):

1. Adapter falls back to `new_session` — agent starts fresh
2. The new `acp_session_id` is persisted, replacing the stale one
3. The prompt is still sent — the user's message is not lost
4. A warning is logged for observability

## Out of Scope

- History replay via `load_session` (iOS has local event history in SwiftData)
- Proactive session reconnection on daemon startup (we only resume lazily on first prompt)
- Session expiry/cleanup policy
