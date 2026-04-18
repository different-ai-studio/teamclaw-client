use std::collections::HashMap;
use tracing::info;
use uuid::Uuid;

use crate::proto::amux;
use super::adapter;
use super::handle::AgentHandle;

pub struct AgentManager {
    agents: HashMap<String, AgentHandle>,
    claude_binary: String,
    /// Tracks the model id currently applied to each agent's ACP session.
    /// Populated on spawn (after the adapter sends the initial set_model)
    /// and updated whenever set_current_model is called. The adapter is
    /// responsible for actually calling ACP `session/set_model`; this map
    /// is the daemon-side mirror used to populate AgentInfo.current_model.
    current_model_per_agent: HashMap<String, String>,
}

impl AgentManager {
    pub fn new(binary: String, _flags: Vec<String>) -> Self {
        Self {
            agents: HashMap::new(),
            claude_binary: binary,
            current_model_per_agent: HashMap::new(),
        }
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

    pub async fn spawn_agent(
        &mut self,
        agent_type: amux::AgentType,
        worktree: &str,
        prompt: &str,
        workspace_id: &str,
    ) -> crate::error::Result<String> {
        let agent_id = Uuid::new_v4().to_string()[..8].to_string();
        let mut handle = AgentHandle::new(agent_id.clone(), agent_type, worktree.into(), workspace_id.into());
        handle.current_prompt = prompt.into();

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

        Ok(agent_id)
    }

    pub async fn stop_agent(&mut self, agent_id: &str) -> Option<AgentHandle> {
        if let Some(mut handle) = self.agents.remove(agent_id) {
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

    pub fn get_handle(&self, agent_id: &str) -> Option<&AgentHandle> {
        self.agents.get(agent_id)
    }

    pub fn get_handle_mut(&mut self, agent_id: &str) -> Option<&mut AgentHandle> {
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
            agents: self
                .agents
                .iter()
                .map(|(id, h)| {
                    let available = crate::agent::models::available_models_for(h.agent_type);
                    let current = self
                        .current_model_per_agent
                        .get(id)
                        .cloned()
                        .unwrap_or_default();
                    h.to_proto_info(available, current)
                })
                .collect(),
        }
    }

    /// Build an `AgentInfo` for a single agent, populating the model fields
    /// from the manager's tracking state. Returns None if the agent is unknown.
    pub fn to_proto_info(&self, agent_id: &str) -> Option<amux::AgentInfo> {
        let handle = self.agents.get(agent_id)?;
        let available = crate::agent::models::available_models_for(handle.agent_type);
        let current = self
            .current_model_per_agent
            .get(agent_id)
            .cloned()
            .unwrap_or_default();
        Some(handle.to_proto_info(available, current))
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
        let mut mgr = AgentManager::new("claude".to_string(), vec![]);
        mgr.set_current_model("agent-1", "claude-sonnet-4-6");
        assert_eq!(
            mgr.current_model("agent-1").map(|s| s.as_str()),
            Some("claude-sonnet-4-6")
        );
    }

    #[test]
    fn current_model_returns_none_for_unknown_agent() {
        let mgr = AgentManager::new("claude".to_string(), vec![]);
        assert_eq!(mgr.current_model("agent-1"), None);
    }
}
