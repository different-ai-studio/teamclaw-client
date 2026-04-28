use std::collections::HashMap;
use tracing::{info, warn};
use uuid::Uuid;

use crate::proto::amux;
use crate::runtime::turn_aggregator::TurnAggregator;
use crate::supabase::{AgentRuntimeUpsert, SupabaseClient};
use chrono::Utc;
use super::adapter;
use super::handle::RuntimeHandle;

pub struct RuntimeManager {
    agents: HashMap<String, RuntimeHandle>,
    pub aggregators: std::collections::HashMap<String, TurnAggregator>,
    claude_binary: String,
    /// Tracks the model id currently applied to each agent's ACP session.
    /// Populated on spawn (after the adapter sends the initial set_model)
    /// and updated whenever set_current_model is called. The adapter is
    /// responsible for actually calling ACP `session/set_model`; this map
    /// is the daemon-side mirror used to populate RuntimeInfo.current_model.
    current_model_per_agent: HashMap<String, String>,
    /// Most recent slash commands reported via ACP `AvailableCommandsUpdate`,
    /// keyed by agent id. Cached so a fresh subscriber on the retained
    /// `runtime/{id}/state` topic sees the same list the agent already
    /// announced earlier on the (non-retained) events topic.
    available_commands_per_agent: HashMap<String, Vec<amux::AcpAvailableCommand>>,
    supabase: Option<SupabaseClient>,
}

impl RuntimeManager {
    pub fn new(binary: String, _flags: Vec<String>, supabase: Option<SupabaseClient>) -> Self {
        Self {
            agents: HashMap::new(),
            aggregators: std::collections::HashMap::new(),
            claude_binary: binary,
            current_model_per_agent: HashMap::new(),
            available_commands_per_agent: HashMap::new(),
            supabase,
        }
    }

    /// Records the latest slash-command list for an agent. Callers feed
    /// this from the adapter's translated `AvailableCommands` events so
    /// `to_proto_info` can include them in retained state.
    pub fn set_available_commands(&mut self, agent_id: &str, commands: Vec<amux::AcpAvailableCommand>) {
        self.available_commands_per_agent
            .insert(agent_id.to_string(), commands);
    }


    /// Records that an agent's session is now running on `model_id`.
    /// Caller is responsible for actually invoking ACP set_model on the
    /// adapter; this only updates the tracking map.
    pub fn set_current_model(&mut self, agent_id: &str, model_id: &str) {
        self.current_model_per_agent
            .insert(agent_id.to_string(), model_id.to_string());
    }

    /// Returns the model id last recorded for `agent_id`, if any.
    pub fn current_model(&self, agent_id: &str) -> Option<&String> {
        self.current_model_per_agent.get(agent_id)
    }

    /// Returns a mutable reference to the per-agent `TurnAggregator`, if any.
    /// Inserted on `spawn_agent` / `resume_agent` and removed on `stop_agent`.
    pub fn aggregator_mut(&mut self, agent_id: &str) -> Option<&mut TurnAggregator> {
        self.aggregators.get_mut(agent_id)
    }

    pub async fn spawn_agent(
        &mut self,
        agent_type: amux::AgentType,
        worktree: &str,
        prompt: &str,
        workspace_id: &str,
        supabase_workspace_id: Option<&str>,
        supabase_session_id: Option<&str>,
    ) -> crate::error::Result<String> {
        let agent_id = Uuid::new_v4().to_string()[..8].to_string();
        let mut handle = RuntimeHandle::new(agent_id.clone(), agent_type, worktree.into(), workspace_id.into());
        handle.current_prompt = prompt.into();
        handle.collab_session_id = supabase_session_id.unwrap_or_default().to_string();

        let (initial_model_tx, initial_model_rx) = tokio::sync::oneshot::channel::<Option<String>>();
        let (acp_session_id_tx, acp_session_id_rx) = tokio::sync::oneshot::channel::<String>();

        let cmd_tx = adapter::spawn_acp_agent(
            self.claude_binary.clone(),
            worktree.to_string(),
            prompt.to_string(),
            agent_type,
            handle.event_tx.clone(),
            initial_model_tx,
            None,
            acp_session_id_tx,
        )?;

        handle.cmd_tx = Some(cmd_tx);
        handle.status = amux::AgentStatus::Active;

        info!(agent_id, worktree, "agent spawned via ACP");
        self.agents.insert(agent_id.clone(), handle);
        self.aggregators.insert(agent_id.clone(), TurnAggregator::new());

        // Wait for the adapter to report the model it applied. None means no
        // model was applied (no models known for this agent type, or the ACP
        // call failed); skip recording in that case.
        if let Ok(Some(model_id)) = initial_model_rx.await {
            self.set_current_model(&agent_id, &model_id);
        }

        // Capture ACP session_id
        if let Ok(acp_sid) = acp_session_id_rx.await {
            if let Some(h) = self.agents.get_mut(&agent_id) {
                h.acp_session_id = acp_sid;
            }
        }

        // Upsert agent_runtimes with status="starting"
        if let Some(sb) = &self.supabase {
            let acp_sid = self.agents.get(&agent_id)
                .map(|h| h.acp_session_id.clone())
                .unwrap_or_default();
            let row = AgentRuntimeUpsert {
                team_id: &sb.config().team_id,
                agent_id: &sb.config().actor_id,
                session_id: supabase_session_id,
                workspace_id: supabase_workspace_id,
                backend_type: "claude",
                backend_session_id: if acp_sid.is_empty() { None } else { Some(&acp_sid) },
                status: "starting",
                current_model: self.current_model_per_agent.get(&agent_id).map(|s| s.as_str()),
                last_seen_at: Utc::now(),
            };
            if let Err(e) = sb.upsert_agent_runtime(&row).await {
                warn!("agent_runtimes upsert (starting): {e}");
            }
        }

        Ok(agent_id)
    }

    pub async fn resume_agent(
        &mut self,
        agent_id: &str,
        acp_session_id: &str,
        agent_type: amux::AgentType,
        worktree: &str,
        workspace_id: &str,
        supabase_workspace_id: Option<&str>,
        supabase_session_id: Option<&str>,
        prompt: &str,
    ) -> crate::error::Result<String> {
        let mut handle = RuntimeHandle::new(
            agent_id.to_string(),
            agent_type,
            worktree.into(),
            workspace_id.into(),
        );
        handle.collab_session_id = supabase_session_id.unwrap_or_default().to_string();

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
        handle.current_prompt = prompt.to_string();

        info!(agent_id, worktree, "agent resumed via ACP");
        self.agents.insert(agent_id.to_string(), handle);
        self.aggregators
            .insert(agent_id.to_string(), TurnAggregator::new());

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

        // Upsert agent_runtimes with status="starting" on resume
        if let Some(sb) = &self.supabase {
            let row = AgentRuntimeUpsert {
                team_id: &sb.config().team_id,
                agent_id: &sb.config().actor_id,
                session_id: supabase_session_id,
                workspace_id: supabase_workspace_id,
                backend_type: "claude",
                backend_session_id: if new_acp_sid.is_empty() { None } else { Some(&new_acp_sid) },
                status: "starting",
                current_model: self.current_model_per_agent.get(agent_id).map(|s| s.as_str()),
                last_seen_at: Utc::now(),
            };
            if let Err(e) = sb.upsert_agent_runtime(&row).await {
                warn!("agent_runtimes upsert (starting/resume): {e}");
            }
        }

        Ok(new_acp_sid)
    }

    pub async fn stop_agent(&mut self, agent_id: &str) -> Option<RuntimeHandle> {
        if let Some(mut handle) = self.agents.remove(agent_id) {
            self.aggregators.remove(agent_id);
            handle.status = amux::AgentStatus::Stopped;
            handle.shutdown().await;
            info!(agent_id, "agent stopped");
            Some(handle)
        } else {
            None
        }
    }

    /// Send a prompt to an existing agent via ACP.
    pub async fn send_prompt(&mut self, agent_id: &str, text: &str) -> crate::error::Result<()> {
        let handle = self.agents.get(agent_id).ok_or_else(|| {
            crate::error::AmuxError::Agent(format!("agent {} not found", agent_id))
        })?;

        handle.send_prompt(text).await
    }

    /// Forward a `SetModel` command onto the agent's ACP command channel.
    /// The adapter is responsible for performing `session/set_model`; the
    /// caller is responsible for updating `current_model_per_agent` once the
    /// command has been queued (we cannot wait for the adapter to confirm
    /// without changing the channel contract).
    pub async fn send_set_model(&mut self, agent_id: &str, model_id: &str) -> crate::error::Result<()> {
        let handle = self.agents.get(agent_id).ok_or_else(|| {
            crate::error::AmuxError::Agent(format!("agent {} not found", agent_id))
        })?;
        let tx = handle.cmd_tx.as_ref().ok_or_else(|| {
            crate::error::AmuxError::Agent("no ACP command channel".into())
        })?;
        tx.send(adapter::AcpCommand::SetModel {
            model_id: model_id.to_string(),
        })
        .await
        .map_err(|_| crate::error::AmuxError::Agent("ACP command channel closed".into()))
    }

    /// Returns an agent_id whose adapter has finished initializing and is ready
    /// for prompts. Excludes Starting (transient) and dead statuses -- an agent
    /// in Starting may crash before becoming Active, and baking that into a
    /// session's `primary_agent_id` would point to a dead slot.
    /// Used to populate the `primary_agent_id` of newly created collab sessions
    /// in v1 (multi-agent sessions are out of scope).
    pub fn first_running_agent_id(&self) -> Option<String> {
        self.agents
            .iter()
            .find(|(_, h)| matches!(
                h.status,
                amux::AgentStatus::Active | amux::AgentStatus::Idle
            ))
            .map(|(id, _)| id.clone())
    }

    pub fn running_agent_id_for_collab_session(
        &self,
        collab_session_id: &str,
    ) -> Option<String> {
        if collab_session_id.is_empty() {
            return None;
        }
        self.agents
            .iter()
            .find(|(_, h)| {
                h.collab_session_id == collab_session_id
                    && matches!(
                        h.status,
                        amux::AgentStatus::Active | amux::AgentStatus::Idle
                    )
            })
            .map(|(id, _)| id.clone())
    }

    /// Cancel the current turn for an agent.
    pub async fn cancel_agent(&mut self, agent_id: &str) -> crate::error::Result<()> {
        let handle = self.agents.get(agent_id).ok_or_else(|| {
            crate::error::AmuxError::Agent(format!("agent {} not found", agent_id))
        })?;

        handle.cancel().await
    }

    /// Resolve a permission request for an agent.
    pub async fn resolve_permission(
        &mut self,
        agent_id: &str,
        request_id: &str,
        granted: bool,
    ) -> crate::error::Result<()> {
        let handle = self.agents.get(agent_id).ok_or_else(|| {
            crate::error::AmuxError::Agent(format!("agent {} not found", agent_id))
        })?;

        handle.resolve_permission(request_id, granted).await
    }

    pub fn get_handle(&self, agent_id: &str) -> Option<&RuntimeHandle> {
        self.agents.get(agent_id)
    }

    pub fn get_handle_mut(&mut self, agent_id: &str) -> Option<&mut RuntimeHandle> {
        self.agents.get_mut(agent_id)
    }

    /// Drain events from all agents, returns (agent_id, event) pairs
    pub fn poll_events(&mut self) -> Vec<(String, amux::AcpEvent)> {
        let mut events = vec![];
        for (agent_id, handle) in &mut self.agents {
            while let Ok(event) = handle.event_rx.try_recv() {
                events.push((agent_id.clone(), event));
            }
        }
        events
    }

    pub fn to_proto_agent_list(&self) -> amux::AgentList {
        amux::AgentList {
            runtimes: self
                .agents
                .iter()
                .map(|(id, h)| {
                    let available = crate::runtime::models::available_models_for(h.agent_type);
                    let current = self
                        .current_model_per_agent
                        .get(id)
                        .cloned()
                        .unwrap_or_default();
                    let commands = self
                        .available_commands_per_agent
                        .get(id)
                        .cloned()
                        .unwrap_or_default();
                    h.to_proto_info(available, current, commands)
                })
                .collect(),
        }
    }

    /// Build a `RuntimeInfo` for a single agent, populating the model fields
    /// from the manager's tracking state. Returns None if the agent is unknown.
    pub fn to_proto_info(&self, agent_id: &str) -> Option<amux::RuntimeInfo> {
        let handle = self.agents.get(agent_id)?;
        let available = crate::runtime::models::available_models_for(handle.agent_type);
        let current = self
            .current_model_per_agent
            .get(agent_id)
            .cloned()
            .unwrap_or_default();
        let commands = self
            .available_commands_per_agent
            .get(agent_id)
            .cloned()
            .unwrap_or_default();
        Some(handle.to_proto_info(available, current, commands))
    }

    pub fn agent_ids(&self) -> Vec<String> {
        self.agents.keys().cloned().collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn set_current_model_records_value() {
        let mut mgr = RuntimeManager::new("claude".to_string(), vec![], None);
        mgr.set_current_model("agent-1", "claude-sonnet-4-6");
        assert_eq!(
            mgr.current_model("agent-1").map(|s| s.as_str()),
            Some("claude-sonnet-4-6")
        );
    }

    #[test]
    fn current_model_returns_none_for_unknown_agent() {
        let mgr = RuntimeManager::new("claude".to_string(), vec![], None);
        assert_eq!(mgr.current_model("agent-1"), None);
    }

    #[test]
    fn running_agent_id_for_collab_session_ignores_stopped_agents() {
        let mut mgr = RuntimeManager::new("claude".to_string(), vec![], None);
        let mut stopped = RuntimeHandle::new(
            "stopped-1".to_string(),
            amux::AgentType::ClaudeCode,
            ".".to_string(),
            "workspace-1".to_string(),
        );
        stopped.collab_session_id = "session-1".to_string();
        stopped.status = amux::AgentStatus::Stopped;

        let mut running = RuntimeHandle::new(
            "running-1".to_string(),
            amux::AgentType::ClaudeCode,
            ".".to_string(),
            "workspace-1".to_string(),
        );
        running.collab_session_id = "session-1".to_string();
        running.status = amux::AgentStatus::Idle;

        mgr.agents.insert(stopped.agent_id.clone(), stopped);
        mgr.agents.insert(running.agent_id.clone(), running);

        assert_eq!(
            mgr.running_agent_id_for_collab_session("session-1").as_deref(),
            Some("running-1")
        );
        assert_eq!(mgr.running_agent_id_for_collab_session("missing"), None);
    }
}
