use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

use crate::proto::teamclaw;

#[derive(Debug, Default, Serialize, Deserialize)]
pub struct TeamclawSessionStore {
    #[serde(default)]
    pub sessions: Vec<StoredCollabSession>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StoredCollabSession {
    pub session_id: String,
    /// "control" or "collab"
    pub session_type: String,
    pub team_id: String,
    pub title: String,
    pub host_device_id: String,
    pub created_by: String,
    pub created_at: DateTime<Utc>,
    pub summary: String,
    #[serde(default)]
    pub participants: Vec<StoredParticipant>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StoredParticipant {
    pub actor_id: String,
    pub actor_type: String,
    pub display_name: String,
    pub joined_at: DateTime<Utc>,
}

impl TeamclawSessionStore {
    pub fn default_path(base_dir: &Path) -> PathBuf {
        base_dir.join("teamclaw").join("sessions.toml")
    }

    pub fn load(path: &Path) -> crate::error::Result<Self> {
        if !path.exists() {
            return Ok(Self::default());
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

    pub fn to_proto_index(&self) -> teamclaw::SessionIndex {
        let sessions = self.sessions.iter().map(|s| {
            teamclaw::SessionIndexEntry {
                session_id: s.session_id.clone(),
                session_type: session_type_to_proto(&s.session_type) as i32,
                title: s.title.clone(),
                host_device_id: s.host_device_id.clone(),
                created_at: s.created_at.timestamp(),
                participant_count: s.participants.len() as i32,
                last_message_preview: String::new(),
                last_message_at: 0,
            }
        }).collect();
        teamclaw::SessionIndex { sessions }
    }

    pub fn to_proto_session_info(&self, session_id: &str) -> Option<teamclaw::SessionInfo> {
        self.find_by_id(session_id).map(|s| {
            let participants = s.participants.iter().map(|p| {
                teamclaw::Participant {
                    actor_id: p.actor_id.clone(),
                    actor_type: actor_type_to_proto(&p.actor_type) as i32,
                    display_name: p.display_name.clone(),
                    joined_at: p.joined_at.timestamp(),
                }
            }).collect();
            teamclaw::SessionInfo {
                session_id: s.session_id.clone(),
                session_type: session_type_to_proto(&s.session_type) as i32,
                team_id: s.team_id.clone(),
                title: s.title.clone(),
                host_device_id: s.host_device_id.clone(),
                created_by: s.created_by.clone(),
                created_at: s.created_at.timestamp(),
                participants,
                summary: s.summary.clone(),
            }
        })
    }
}

fn session_type_to_proto(s: &str) -> teamclaw::SessionType {
    match s {
        "control" => teamclaw::SessionType::Control,
        "collab" => teamclaw::SessionType::Collab,
        _ => teamclaw::SessionType::Unknown,
    }
}

fn actor_type_to_proto(s: &str) -> teamclaw::ActorType {
    match s {
        "human" => teamclaw::ActorType::Human,
        "personal_agent" => teamclaw::ActorType::PersonalAgent,
        "role_agent" => teamclaw::ActorType::RoleAgent,
        _ => teamclaw::ActorType::Unknown,
    }
}
