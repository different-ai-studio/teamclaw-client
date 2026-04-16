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
}

pub fn parse_incoming(publish: &Publish) -> Option<IncomingMessage> {
    let topic = &publish.topic;

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
