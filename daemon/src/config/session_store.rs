use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

use crate::proto::amux;

#[derive(Debug, Default, Serialize, Deserialize)]
pub struct SessionStore {
    #[serde(default)]
    pub sessions: Vec<StoredSession>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StoredSession {
    pub session_id: String,
    #[serde(default)]
    pub acp_session_id: String,
    #[serde(default)]
    pub collab_session_id: String,
    pub agent_type: i32,
    pub workspace_id: String,
    pub worktree: String,
    pub status: i32,
    pub created_at: i64,
    pub last_prompt: String,
    pub last_output_summary: String,
    pub tool_use_count: i32,
}

impl SessionStore {
    pub fn default_path() -> PathBuf {
        super::DaemonConfig::config_dir().join("sessions.toml")
    }

    pub fn load(path: &Path) -> crate::error::Result<Self> {
        if !path.exists() {
            return Ok(Self { sessions: vec![] });
        }
        let content = std::fs::read_to_string(path)
            .map_err(|e| crate::error::AmuxError::Config(format!("read {}: {}", path.display(), e)))?;
        toml::from_str(&content)
            .map_err(|e| crate::error::AmuxError::Config(format!("parse {}: {}", path.display(), e)))
    }

    pub fn save(&self, path: &Path) -> crate::error::Result<()> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let content = toml::to_string_pretty(self)
            .map_err(|e| crate::error::AmuxError::Config(e.to_string()))?;
        std::fs::write(path, content)?;
        Ok(())
    }

    pub fn upsert(&mut self, session: StoredSession) {
        if let Some(existing) = self.sessions.iter_mut().find(|s| s.session_id == session.session_id) {
            *existing = session;
        } else {
            self.sessions.push(session);
        }
    }

    pub fn find_by_id(&self, session_id: &str) -> Option<&StoredSession> {
        self.sessions.iter().find(|s| s.session_id == session_id)
    }

    pub fn find_by_id_mut(&mut self, session_id: &str) -> Option<&mut StoredSession> {
        self.sessions.iter_mut().find(|s| s.session_id == session_id)
    }

    pub fn to_proto_agent_list(&self) -> Vec<amux::RuntimeInfo> {
        self.sessions.iter().map(Self::session_to_info).collect()
    }

    pub fn to_proto_agent_info(&self, session_id: &str) -> Option<amux::RuntimeInfo> {
        self.find_by_id(session_id).map(Self::session_to_info)
    }

    fn session_to_info(s: &StoredSession) -> amux::RuntimeInfo {
        amux::RuntimeInfo {
            runtime_id: s.session_id.clone(),
            agent_type: s.agent_type,
            worktree: s.worktree.clone(),
            branch: String::new(),
            status: s.status,
            started_at: s.created_at,
            current_prompt: s.last_prompt.clone(),
            workspace_id: s.workspace_id.clone(),
            session_title: String::new(),
            last_output_summary: s.last_output_summary.clone(),
            tool_use_count: s.tool_use_count,
            // Historical (non-active) sessions have no live model state.
            // Live agents are merged in by `DaemonServer::merged_agent_list`
            // from `RuntimeManager::to_proto_agent_list`, which populates
            // these fields from the running adapter.
            available_models: vec![],
            current_model: String::new(),
            // Stored sessions represent runtimes the daemon will re-spawn.
            // ACTIVE is a steady-state assumption; Phase 1b will wire proper
            // state transitions (STARTING while spawn is in flight, FAILED
            // if spawn fails).
            state: amux::RuntimeLifecycle::Active as i32,
            stage: String::new(),
            error_code: String::new(),
            error_message: String::new(),
            failed_stage: String::new(),
        }
    }
}
