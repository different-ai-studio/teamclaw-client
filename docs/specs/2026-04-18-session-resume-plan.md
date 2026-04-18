# Session Resume Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When a user sends a prompt to a historical (non-live) session, the daemon lazily resumes the ACP session instead of returning "agent not found".

**Architecture:** Add `acp_session_id` tracking to `AgentHandle` and `StoredSession`. Extend `spawn_acp_agent` to optionally call `resume_session` instead of `new_session`. Add `resume_agent` to `AgentManager`. Intercept "agent not found" in the `SendPrompt` handler to trigger lazy resume.

**Tech Stack:** Rust, agent-client-protocol 0.10.4 (`unstable_session_resume` feature)

---

### Task 1: Enable `unstable_session_resume` feature

**Files:**
- Modify: `daemon/Cargo.toml:8`

- [ ] **Step 1: Add the feature flag**

In `daemon/Cargo.toml`, change:

```toml
agent-client-protocol = { version = "0.10.4", features = ["unstable_session_model", "unstable_session_resume"] }
```

- [ ] **Step 2: Verify it compiles**

Run: `cd daemon && cargo check`
Expected: compiles with no errors

- [ ] **Step 3: Commit**

```bash
git add daemon/Cargo.toml
git commit -m "feat(daemon): enable unstable_session_resume ACP feature"
```

---

### Task 2: Add `acp_session_id` to `StoredSession` and `AgentHandle`

**Files:**
- Modify: `daemon/src/config/session_store.rs:13-23`
- Modify: `daemon/src/agent/handle.rs:7-46`

- [ ] **Step 1: Add field to `StoredSession`**

In `daemon/src/config/session_store.rs`, add to the `StoredSession` struct after `session_id`:

```rust
#[serde(default)]
pub acp_session_id: String,
```

`#[serde(default)]` ensures backward compatibility with existing `sessions.toml` files that lack this field.

- [ ] **Step 2: Add field to `AgentHandle`**

In `daemon/src/agent/handle.rs`, add to the `AgentHandle` struct after `agent_id`:

```rust
pub acp_session_id: String,
```

In `AgentHandle::new()`, initialize it:

```rust
acp_session_id: String::new(),
```

- [ ] **Step 3: Verify it compiles**

Run: `cd daemon && cargo check`
Expected: compiles with no errors

- [ ] **Step 4: Commit**

```bash
git add daemon/src/config/session_store.rs daemon/src/agent/handle.rs
git commit -m "feat(daemon): add acp_session_id to StoredSession and AgentHandle"
```

---

### Task 3: Bubble `acp_session_id` out of the adapter

**Files:**
- Modify: `daemon/src/agent/adapter.rs:375-415` (spawn_acp_agent signature)
- Modify: `daemon/src/agent/adapter.rs:417-530` (run_acp_session)
- Modify: `daemon/src/agent/manager.rs:42-78` (spawn_agent caller)

- [ ] **Step 1: Add `resume_acp_session_id` param and `acp_session_id_tx` oneshot to `spawn_acp_agent`**

Change the signature of `spawn_acp_agent` in `daemon/src/agent/adapter.rs`:

```rust
pub fn spawn_acp_agent(
    binary: String,
    worktree: String,
    initial_prompt: String,
    agent_type: amux::AgentType,
    event_tx: mpsc::Sender<amux::AcpEvent>,
    initial_model_tx: oneshot::Sender<Option<String>>,
    resume_acp_session_id: Option<String>,
    acp_session_id_tx: oneshot::Sender<String>,
) -> crate::error::Result<mpsc::Sender<AcpCommand>> {
```

Pass the two new params into `run_acp_session`:

```rust
if let Err(e) = run_acp_session(
    binary,
    worktree,
    initial_prompt,
    agent_type,
    event_tx,
    cmd_rx,
    initial_model_tx,
    resume_acp_session_id,
    acp_session_id_tx,
)
```

- [ ] **Step 2: Update `run_acp_session` signature and session creation logic**

Add the two new params to `run_acp_session`:

```rust
async fn run_acp_session(
    binary: String,
    worktree: String,
    initial_prompt: String,
    agent_type: amux::AgentType,
    event_tx: mpsc::Sender<amux::AcpEvent>,
    mut cmd_rx: mpsc::Receiver<AcpCommand>,
    initial_model_tx: oneshot::Sender<Option<String>>,
    resume_acp_session_id: Option<String>,
    acp_session_id_tx: oneshot::Sender<String>,
) -> anyhow::Result<()> {
```

Replace the `new_session` block (lines ~493-501) with:

```rust
    // Create or resume session
    let worktree_path = std::path::PathBuf::from(&worktree);
    let session_id = if let Some(ref resume_id) = resume_acp_session_id {
        let resume_req = acp::ResumeSessionRequest::new(
            acp::SessionId::new(resume_id.clone()),
            worktree_path.clone(),
        );
        match conn.resume_session(resume_req).await {
            Ok(resp) => {
                let sid = resp.session_id.clone();
                info!(session_id = %sid, "ACP session resumed");
                sid
            }
            Err(e) => {
                warn!(resume_id, "ACP resume_session failed ({}), falling back to new_session", e);
                let resp = conn
                    .new_session(acp::NewSessionRequest::new(worktree_path))
                    .await
                    .map_err(|e| anyhow::anyhow!("ACP new_session failed: {}", e))?;
                let sid = resp.session_id.clone();
                info!(session_id = %sid, "ACP session created (fallback)");
                sid
            }
        }
    } else {
        let resp = conn
            .new_session(acp::NewSessionRequest::new(worktree_path))
            .await
            .map_err(|e| anyhow::anyhow!("ACP new_session failed: {}", e))?;
        let sid = resp.session_id.clone();
        info!(session_id = %sid, "ACP session created");
        sid
    };

    // Report the ACP session_id back to the caller
    let _ = acp_session_id_tx.send(session_id.to_string());
```

- [ ] **Step 3: Update `AgentManager::spawn_agent` to pass new params and capture `acp_session_id`**

In `daemon/src/agent/manager.rs`, update `spawn_agent`:

```rust
    pub async fn spawn_agent(
        &mut self,
        agent_type: amux::AgentType,
        worktree: &str,
        prompt: &str,
        workspace_id: &str,
    ) -> crate::error::Result<String> {
        let agent_id = Uuid::new_v4().to_string()[..8].to_string();
        let mut handle = AgentHandle::new(agent_id.clone(), agent_type, worktree.into(), workspace_id.into());

        let (initial_model_tx, initial_model_rx) = tokio::sync::oneshot::channel::<Option<String>>();
        let (acp_session_id_tx, acp_session_id_rx) = tokio::sync::oneshot::channel::<String>();

        let cmd_tx = adapter::spawn_acp_agent(
            self.claude_binary.clone(),
            worktree.to_string(),
            prompt.to_string(),
            agent_type,
            handle.event_tx.clone(),
            initial_model_tx,
            None,  // no resume for new agents
            acp_session_id_tx,
        )?;
        handle.cmd_tx = Some(cmd_tx);
        handle.status = amux::AgentStatus::Active;

        info!(agent_id, worktree, "agent spawned via ACP");
        self.agents.insert(agent_id.clone(), handle);

        // Capture initial model
        if let Ok(Some(model_id)) = initial_model_rx.await {
            self.set_current_model(&agent_id, &model_id);
        }

        // Capture ACP session_id
        if let Ok(acp_sid) = acp_session_id_rx.await {
            if let Some(h) = self.agents.get_mut(&agent_id) {
                h.acp_session_id = acp_sid;
            }
        }

        Ok(agent_id)
    }
```

- [ ] **Step 4: Verify it compiles**

Run: `cd daemon && cargo check`
Expected: compiles with no errors

- [ ] **Step 5: Commit**

```bash
git add daemon/src/agent/adapter.rs daemon/src/agent/manager.rs
git commit -m "feat(daemon): bubble acp_session_id from adapter, support resume_session"
```

---

### Task 4: Persist `acp_session_id` in the server's spawn flow

**Files:**
- Modify: `daemon/src/daemon/server.rs:445-462`

- [ ] **Step 1: Update the `StoredSession` creation to include `acp_session_id`**

In `server.rs`, after `spawn_agent` succeeds, the server creates a `StoredSession`. Update it to also capture `acp_session_id` from the handle:

```rust
                match self.agents.spawn_agent(at, &worktree, &start.initial_prompt, &ws_id).await {
                    Ok(new_id) => {
                        info!(agent_id = %new_id, peer_id, "agent started");
                        let acp_sid = self.agents.get_handle(&new_id)
                            .map(|h| h.acp_session_id.clone())
                            .unwrap_or_default();
                        let stored = StoredSession {
                            session_id: new_id.clone(),
                            acp_session_id: acp_sid,
                            agent_type: at as i32,
                            workspace_id: ws_id.clone(),
                            worktree: worktree.clone(),
                            status: amux::AgentStatus::Active as i32,
                            created_at: chrono::Utc::now().timestamp(),
                            last_prompt: start.initial_prompt.clone(),
                            last_output_summary: String::new(),
                            tool_use_count: 0,
                        };
                        self.sessions.upsert(stored);
                        let _ = self.sessions.save(&self.sessions_path);
```

- [ ] **Step 2: Verify it compiles**

Run: `cd daemon && cargo check`
Expected: compiles with no errors

- [ ] **Step 3: Commit**

```bash
git add daemon/src/daemon/server.rs
git commit -m "feat(daemon): persist acp_session_id on agent spawn"
```

---

### Task 5: Add `resume_agent` to `AgentManager`

**Files:**
- Modify: `daemon/src/agent/manager.rs`

- [ ] **Step 1: Add the `resume_agent` method**

Add after `spawn_agent` in `AgentManager`:

```rust
    /// Resume a previously persisted agent session.
    ///
    /// Spawns a new ACP process and calls `resume_session` with the given
    /// `acp_session_id`. Reuses the existing `agent_id` instead of generating
    /// a new one. Returns the (possibly new) ACP session_id — if resume
    /// failed and fell back to `new_session`, the returned id will differ
    /// from the input.
    pub async fn resume_agent(
        &mut self,
        agent_id: &str,
        acp_session_id: &str,
        agent_type: amux::AgentType,
        worktree: &str,
        workspace_id: &str,
        prompt: &str,
    ) -> crate::error::Result<String> {
        let mut handle = AgentHandle::new(
            agent_id.to_string(),
            agent_type,
            worktree.into(),
            workspace_id.into(),
        );

        let (initial_model_tx, initial_model_rx) = tokio::sync::oneshot::channel::<Option<String>>();
        let (acp_session_id_tx, acp_session_id_rx) = tokio::sync::oneshot::channel::<String>();

        let cmd_tx = adapter::spawn_acp_agent(
            self.claude_binary.clone(),
            worktree.to_string(),
            prompt.to_string(),
            agent_type,
            handle.event_tx.clone(),
            initial_model_tx,
            Some(acp_session_id.to_string()),
            acp_session_id_tx,
        )?;
        handle.cmd_tx = Some(cmd_tx);
        handle.status = amux::AgentStatus::Active;

        info!(agent_id, worktree, "agent resumed via ACP");
        self.agents.insert(agent_id.to_string(), handle);

        // Capture initial model
        if let Ok(Some(model_id)) = initial_model_rx.await {
            self.set_current_model(agent_id, &model_id);
        }

        // Capture ACP session_id (may differ from input if resume failed)
        let new_acp_sid = if let Ok(sid) = acp_session_id_rx.await {
            if let Some(h) = self.agents.get_mut(agent_id) {
                h.acp_session_id = sid.clone();
            }
            sid
        } else {
            acp_session_id.to_string()
        };

        Ok(new_acp_sid)
    }
```

- [ ] **Step 2: Verify it compiles**

Run: `cd daemon && cargo check`
Expected: compiles with no errors

- [ ] **Step 3: Commit**

```bash
git add daemon/src/agent/manager.rs
git commit -m "feat(daemon): add AgentManager::resume_agent for lazy session resume"
```

---

### Task 6: Lazy resume in the `SendPrompt` handler

**Files:**
- Modify: `daemon/src/daemon/server.rs:484-540`

- [ ] **Step 1: Add lazy resume before the `send_prompt` call**

Replace the `SendPrompt` handler (lines ~484-540) with logic that attempts resume when the agent is not live. Insert the resume block **before** the existing `send_prompt` call:

```rust
            amux::acp_command::Command::SendPrompt(prompt) => {
                // Lazy resume: if agent is not live but exists in session store,
                // spawn a new ACP process and resume the session.
                if self.agents.get_handle(agent_id).is_none() {
                    if let Some(stored) = self.sessions.find_by_id(agent_id) {
                        let at = amux::AgentType::try_from(stored.agent_type)
                            .unwrap_or(amux::AgentType::ClaudeCode);
                        let worktree = stored.worktree.clone();
                        let ws_id = stored.workspace_id.clone();
                        let acp_sid = stored.acp_session_id.clone();
                        info!(agent_id, "lazy-resuming historical session");
                        match self.agents.resume_agent(
                            agent_id, &acp_sid, at, &worktree, &ws_id, &prompt.text,
                        ).await {
                            Ok(new_acp_sid) => {
                                // Update stored session with potentially new acp_session_id
                                if let Some(s) = self.sessions.find_by_id_mut(agent_id) {
                                    s.acp_session_id = new_acp_sid;
                                    s.status = amux::AgentStatus::Active as i32;
                                    s.last_prompt = prompt.text.clone();
                                }
                                let _ = self.sessions.save(&self.sessions_path);
                                info!(agent_id, peer_id, "session resumed, prompt sent");
                                self.publish_collab_event(agent_id, amux::CollabEvent {
                                    event: Some(amux::collab_event::Event::PromptAccepted(amux::PromptAccepted {
                                        command_id,
                                    })),
                                }).await;
                                let _ = publisher.publish_agent_list(&self.merged_agent_list()).await;
                            }
                            Err(e) => {
                                warn!(agent_id, "lazy resume failed: {}", e);
                            }
                        }
                        return;
                    }
                }

                // Check busy
                if let Some(handle) = self.agents.get_handle(agent_id) {
                    // ... rest of existing SendPrompt handler unchanged ...
```

The key insight: `resume_agent` already sends the initial prompt via the adapter, so we `return` after resume — we don't fall through to the normal `send_prompt` path.

- [ ] **Step 2: Verify it compiles**

Run: `cd daemon && cargo check`
Expected: compiles with no errors

- [ ] **Step 3: Manual test**

1. Start daemon: `cd daemon && RUST_LOG=amuxd=debug cargo run -- start`
2. From iOS, create a new session and send a prompt — verify it works normally
3. Restart the daemon (Ctrl+C, then `cargo run -- start` again)
4. From iOS, tap the same session and send a new prompt
5. Expected: daemon logs show "lazy-resuming historical session" and the prompt goes through
6. If the ACP session expired, expect "resume_session failed... falling back to new_session"

- [ ] **Step 4: Commit**

```bash
git add daemon/src/daemon/server.rs
git commit -m "feat(daemon): lazy resume on SendPrompt to historical sessions"
```
