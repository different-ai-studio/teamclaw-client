use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

#[derive(Debug, Serialize, Deserialize)]
pub struct MemberStore {
    #[serde(default)]
    pub members: Vec<StoredMember>,
    #[serde(default)]
    pub pending_invites: Vec<PendingInvite>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StoredMember {
    pub member_id: String,
    pub display_name: String,
    pub role: String,
    pub token: String,
    pub joined_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PendingInvite {
    pub invite_token: String,
    pub display_name: String,
    pub created_at: DateTime<Utc>,
    pub expires_at: DateTime<Utc>,
}

impl StoredMember {
    pub fn is_owner(&self) -> bool {
        self.role == "owner"
    }
}

impl PendingInvite {
    pub fn is_expired(&self) -> bool {
        Utc::now() > self.expires_at
    }
}

impl MemberStore {
    pub fn default_path() -> PathBuf {
        super::DaemonConfig::config_dir().join("members.toml")
    }

    pub fn load(path: &Path) -> crate::error::Result<Self> {
        if !path.exists() {
            return Ok(Self {
                members: vec![],
                pending_invites: vec![],
            });
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

    pub fn find_member_by_token(&self, token: &str) -> Option<&StoredMember> {
        self.members.iter().find(|m| m.token == token)
    }

    pub fn find_pending_invite(&self, token: &str) -> Option<&PendingInvite> {
        self.pending_invites.iter().find(|i| i.invite_token == token && !i.is_expired())
    }

    pub fn add_member(&mut self, member: StoredMember) {
        self.members.push(member);
    }

    pub fn remove_member(&mut self, member_id: &str) -> bool {
        let len = self.members.len();
        self.members.retain(|m| m.member_id != member_id);
        self.members.len() < len
    }

    pub fn consume_invite(&mut self, token: &str) -> Option<PendingInvite> {
        if let Some(pos) = self.pending_invites.iter().position(|i| i.invite_token == token) {
            Some(self.pending_invites.remove(pos))
        } else {
            None
        }
    }

    pub fn add_invite(&mut self, invite: PendingInvite) {
        self.pending_invites.push(invite);
    }
}
