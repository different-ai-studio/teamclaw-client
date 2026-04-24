use tokio::sync::mpsc;
use tracing::warn;

use crate::proto::amux;
use super::adapter::AcpCommand;

pub struct RuntimeHandle {
    pub agent_id: String,
    pub acp_session_id: String,
    pub collab_session_id: String,
    pub agent_type: amux::AgentType,
    pub worktree: String,
    pub workspace_id: String,
    pub branch: String,
    pub status: amux::AgentStatus,
    pub current_prompt: String,
    pub session_title: String,
    pub last_output_summary: String,
    pub tool_use_count: i32,
    pub started_at: i64,
    pub sequence: u64,
    pub event_rx: mpsc::Receiver<amux::AcpEvent>,
    pub event_tx: mpsc::Sender<amux::AcpEvent>,
    /// Channel to send commands (prompt, cancel, permission) to the ACP thread.
    pub cmd_tx: Option<mpsc::Sender<AcpCommand>>,
}

impl RuntimeHandle {
    pub fn new(agent_id: String, agent_type: amux::AgentType, worktree: String, workspace_id: String) -> Self {
        let (event_tx, event_rx) = mpsc::channel(256);
        Self {
            agent_id,
            acp_session_id: String::new(),
            collab_session_id: String::new(),
            agent_type,
            worktree,
            workspace_id,
            branch: String::new(),
            status: amux::AgentStatus::Starting,
            current_prompt: String::new(),
            session_title: String::new(),
            last_output_summary: String::new(),
            tool_use_count: 0,
            started_at: chrono::Utc::now().timestamp(),
            sequence: 0,
            event_rx,
            event_tx,
            cmd_tx: None,
        }
    }

    pub fn next_sequence(&mut self) -> u64 {
        self.sequence += 1;
        self.sequence
    }

    /// Build a `RuntimeInfo` for this agent.
    ///
    /// `available_models` and `current_model` are passed in by the caller
    /// (typically `RuntimeManager`) so that the handle does not need to know
    /// about the model registry or the daemon-side `current_model_per_agent`
    /// map. Pass an empty Vec / empty String for unknown / unset.
    pub fn to_proto_info(
        &self,
        available_models: Vec<amux::ModelInfo>,
        current_model: String,
    ) -> amux::RuntimeInfo {
        amux::RuntimeInfo {
            runtime_id: self.agent_id.clone(),
            agent_type: self.agent_type as i32,
            worktree: self.worktree.clone(),
            branch: self.branch.clone(),
            status: self.status as i32,
            started_at: self.started_at,
            current_prompt: self.current_prompt.clone(),
            workspace_id: self.workspace_id.clone(),
            session_title: self.session_title.clone(),
            last_output_summary: self.last_output_summary.clone(),
            tool_use_count: self.tool_use_count,
            available_models,
            current_model,
            // Lifecycle fields — not yet populated by the live adapter;
            // will be wired in a later phase.
            state: amux::RuntimeLifecycle::Active as i32,
            stage: String::new(),
            error_code: String::new(),
            error_message: String::new(),
            failed_stage: String::new(),
        }
    }

    /// Send a prompt to the ACP agent via the command channel.
    pub async fn send_prompt(&self, text: &str) -> crate::error::Result<()> {
        if let Some(ref tx) = self.cmd_tx {
            tx.send(AcpCommand::Prompt {
                text: text.to_string(),
            })
            .await
            .map_err(|_| crate::error::AmuxError::Agent("ACP command channel closed".into()))
        } else {
            Err(crate::error::AmuxError::Agent(
                "no ACP command channel".into(),
            ))
        }
    }

    /// Cancel the current turn via ACP.
    pub async fn cancel(&self) -> crate::error::Result<()> {
        if let Some(ref tx) = self.cmd_tx {
            tx.send(AcpCommand::Cancel)
                .await
                .map_err(|_| crate::error::AmuxError::Agent("ACP command channel closed".into()))
        } else {
            Err(crate::error::AmuxError::Agent(
                "no ACP command channel".into(),
            ))
        }
    }

    /// Resolve a pending permission request via ACP.
    pub async fn resolve_permission(
        &self,
        request_id: &str,
        granted: bool,
    ) -> crate::error::Result<()> {
        if let Some(ref tx) = self.cmd_tx {
            tx.send(AcpCommand::ResolvePermission {
                request_id: request_id.to_string(),
                granted,
            })
            .await
            .map_err(|_| crate::error::AmuxError::Agent("ACP command channel closed".into()))
        } else {
            Err(crate::error::AmuxError::Agent(
                "no ACP command channel".into(),
            ))
        }
    }

    /// Shut down the ACP agent gracefully.
    pub async fn shutdown(&self) {
        if let Some(ref tx) = self.cmd_tx {
            let _ = tx.send(AcpCommand::Shutdown).await;
        }
    }
}
