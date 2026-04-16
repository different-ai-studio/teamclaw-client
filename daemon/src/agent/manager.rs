use std::collections::HashMap;
use tracing::info;
use uuid::Uuid;

use crate::proto::amux;
use super::adapter;
use super::handle::AgentHandle;

pub struct AgentManager {
    agents: HashMap<String, AgentHandle>,
    claude_binary: String,
}

impl AgentManager {
    pub fn new(binary: String, _flags: Vec<String>) -> Self {
        Self {
            agents: HashMap::new(),
            claude_binary: binary,
        }
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

        let cmd_tx = adapter::spawn_acp_agent(
            self.claude_binary.clone(),
            worktree.to_string(),
            prompt.to_string(),
            handle.event_tx.clone(),
        )?;

        handle.cmd_tx = Some(cmd_tx);
        handle.status = amux::AgentStatus::Active;

        info!(agent_id, worktree, "agent spawned via ACP");
        self.agents.insert(agent_id.clone(), handle);
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
            agents: self.agents.values().map(|h| h.to_proto_info()).collect(),
        }
    }

    pub fn agent_ids(&self) -> Vec<String> {
        self.agents.keys().cloned().collect()
    }
}
