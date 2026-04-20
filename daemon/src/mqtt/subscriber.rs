use prost::Message;
use rumqttc::Publish;
use tracing::warn;

use crate::proto::amux;

pub enum IncomingMessage {
    AgentCommand {
        agent_id: String,
        envelope: amux::CommandEnvelope,
    },
    DeviceCollab {
        envelope: amux::DeviceCommandEnvelope,
    },
    TeamclawRpc {
        topic: String,
        payload: Vec<u8>,
    },
    TeamclawSessionMessage {
        session_id: String,
        payload: Vec<u8>,
    },
    TeamclawTaskEvent {
        session_id: String,
        payload: Vec<u8>,
    },
}

pub fn parse_incoming(publish: &Publish) -> Option<IncomingMessage> {
    let topic = &publish.topic;

    // Teamclaw topic matching (checked before AMUX topics)
    if topic.starts_with("teamclaw/") {
        if topic.ends_with("/req") {
            return Some(IncomingMessage::TeamclawRpc {
                topic: topic.clone(),
                payload: publish.payload.to_vec(),
            });
        }
        // teamclaw/{team_id}/session/{session_id}/messages  or  /tasks
        let parts: Vec<&str> = topic.split('/').collect();
        if parts.len() == 5 && parts[2] == "session" {
            let session_id = parts[3].to_string();
            match parts[4] {
                "messages" => {
                    return Some(IncomingMessage::TeamclawSessionMessage {
                        session_id,
                        payload: publish.payload.to_vec(),
                    });
                }
                "tasks" => {
                    return Some(IncomingMessage::TeamclawTaskEvent {
                        session_id,
                        payload: publish.payload.to_vec(),
                    });
                }
                _ => {}
            }
        }
    }

    if topic.contains("/agent/") && topic.ends_with("/commands") {
        let parts: Vec<&str> = topic.split('/').collect();
        if parts.len() >= 5 {
            let agent_id = parts[3].to_string();
            match amux::CommandEnvelope::decode(publish.payload.as_ref()) {
                Ok(envelope) => return Some(IncomingMessage::AgentCommand { agent_id, envelope }),
                Err(e) => warn!("failed to decode CommandEnvelope: {}", e),
            }
        }
    } else if topic.ends_with("/collab") {
        // The daemon both publishes DeviceCollabEvent and subscribes to this topic,
        // so it receives its own events back. Try decoding as a command first;
        // silently ignore decode failures (they're likely self-published events).
        if let Ok(envelope) = amux::DeviceCommandEnvelope::decode(publish.payload.as_ref()) {
            // Extra check: real commands have a non-empty peer_id
            if !envelope.peer_id.is_empty() {
                return Some(IncomingMessage::DeviceCollab { envelope });
            }
        }
    }

    None
}
