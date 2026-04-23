use chrono::Utc;
use prost::Message;
use rumqttc::{AsyncClient, QoS};
use uuid::Uuid;

use crate::proto::teamclaw::NotifyEnvelope;
use crate::teamclaw::TeamclawTopics;

pub struct NotifyPublisher {
    client: AsyncClient,
    team_id: String,
}

impl NotifyPublisher {
    pub fn new(client: AsyncClient, team_id: String) -> Self {
        Self { client, team_id }
    }

    pub async fn publish_membership_refresh(
        &self,
        target_device_id: &str,
        session_id: &str,
        reason: &str,
    ) -> crate::error::Result<()> {
        let payload = NotifyEnvelope {
            event_id: Uuid::new_v4().to_string(),
            event_type: "membership.refresh".to_string(),
            target_device_id: target_device_id.to_string(),
            session_id: session_id.to_string(),
            sent_at: Utc::now().timestamp(),
            reason: reason.to_string(),
        }
        .encode_to_vec();

        let topic = TeamclawTopics::new(&self.team_id, target_device_id).device_notify();
        self.client
            .publish(topic, QoS::AtLeastOnce, false, payload)
            .await?;
        Ok(())
    }
}
