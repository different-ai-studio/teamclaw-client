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
    TeamclawNotify {
        device_id: String,
        payload: Vec<u8>,
    },
    TeamclawSessionLive {
        session_id: String,
        payload: Vec<u8>,
    },
    TeamclawSessionMessage {
        session_id: String,
        payload: Vec<u8>,
    },
    TeamclawSessionMeta {
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

    if topic.starts_with("amux/") && topic.contains("/rpc/") {
        if topic.ends_with("/req") {
            return Some(IncomingMessage::TeamclawRpc {
                topic: topic.clone(),
                payload: publish.payload.to_vec(),
            });
        }
    }

    // Team-scoped collaboration topics are matched before device-scoped topics.
    if topic.starts_with("amux/") && !topic.contains("/device/") {
        let parts: Vec<&str> = topic.split('/').collect();

        // amux/{team_id}/tasks
        if parts.len() == 3 && parts[2] == "tasks" {
            return Some(IncomingMessage::TeamclawTaskEvent {
                session_id: String::new(),
                payload: publish.payload.to_vec(),
            });
        }

        // amux/{team_id}/session/{session_id}/messages or /tasks
        if parts.len() == 5 && parts[2] == "session" {
            let session_id = parts[3].to_string();
            match parts[4] {
                "live" => {
                    return Some(IncomingMessage::TeamclawSessionLive {
                        session_id,
                        payload: publish.payload.to_vec(),
                    });
                }
                "messages" => {
                    return Some(IncomingMessage::TeamclawSessionMessage {
                        session_id,
                        payload: publish.payload.to_vec(),
                    });
                }
                "meta" => {
                    return Some(IncomingMessage::TeamclawSessionMeta {
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
        // amux/{team_id}/actor/{actor_id}/session/{session_id}/meta
        if parts.len() == 7 && parts[2] == "actor" && parts[4] == "session" && parts[6] == "meta" {
            return Some(IncomingMessage::TeamclawSessionMeta {
                session_id: parts[5].to_string(),
                payload: publish.payload.to_vec(),
            });
        }
    }

    if topic.starts_with("amux/") && topic.contains("/device/") {
        let parts: Vec<&str> = topic.split('/').collect();
        if parts.len() == 5 && parts[2] == "device" && parts[4] == "notify" {
            return Some(IncomingMessage::TeamclawNotify {
                device_id: parts[3].to_string(),
                payload: publish.payload.to_vec(),
            });
        }
    }

    if topic.contains("/agent/") && topic.ends_with("/commands") {
        let parts: Vec<&str> = topic.split('/').collect();
        if parts.len() >= 7 {
            let agent_id = parts[5].to_string();
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
