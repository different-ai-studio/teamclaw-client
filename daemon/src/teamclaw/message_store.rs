use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use std::path::Path;

use crate::proto::teamclaw;

#[derive(Debug, Default, Serialize, Deserialize)]
pub struct MessageStore {
    #[serde(default)]
    pub messages: Vec<StoredMessage>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StoredMessage {
    pub message_id: String,
    pub session_id: String,
    pub sender_actor_id: String,
    pub kind: String,
    pub content: String,
    pub created_at: DateTime<Utc>,
    #[serde(default)]
    pub reply_to_message_id: String,
    #[serde(default)]
    pub mentions: Vec<String>,
}

impl MessageStore {
    fn path_for(base_dir: &Path, session_id: &str) -> std::path::PathBuf {
        base_dir
            .join("teamclaw")
            .join("sessions")
            .join(session_id)
            .join("messages.toml")
    }

    pub fn load(base_dir: &Path, session_id: &str) -> crate::error::Result<Self> {
        let path = Self::path_for(base_dir, session_id);
        if !path.exists() {
            return Ok(Self::default());
        }
        let content = std::fs::read_to_string(&path)
            .map_err(|e| crate::error::AmuxError::Config(format!("read {}: {}", path.display(), e)))?;
        toml::from_str(&content)
            .map_err(|e| crate::error::AmuxError::Config(format!("parse {}: {}", path.display(), e)))
    }

    pub fn save(&self, base_dir: &Path, session_id: &str) -> crate::error::Result<()> {
        let path = Self::path_for(base_dir, session_id);
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let content = toml::to_string_pretty(self)
            .map_err(|e| crate::error::AmuxError::Config(e.to_string()))?;
        std::fs::write(&path, content)?;
        Ok(())
    }

    pub fn append(&mut self, message: StoredMessage) {
        self.messages.push(message);
    }

    pub fn recent(&self, n: usize) -> &[StoredMessage] {
        let len = self.messages.len();
        if n >= len {
            &self.messages
        } else {
            &self.messages[len - n..]
        }
    }

    pub fn to_proto(msg: &StoredMessage) -> teamclaw::Message {
        teamclaw::Message {
            message_id: msg.message_id.clone(),
            session_id: msg.session_id.clone(),
            sender_actor_id: msg.sender_actor_id.clone(),
            kind: message_kind_to_proto(&msg.kind) as i32,
            content: msg.content.clone(),
            created_at: msg.created_at.timestamp(),
            reply_to_message_id: msg.reply_to_message_id.clone(),
            mentions: msg.mentions.clone(),
        }
    }
}

fn message_kind_to_proto(s: &str) -> teamclaw::MessageKind {
    match s {
        "text" => teamclaw::MessageKind::Text,
        "system" => teamclaw::MessageKind::System,
        "work_event" => teamclaw::MessageKind::WorkEvent,
        _ => teamclaw::MessageKind::Unknown,
    }
}
