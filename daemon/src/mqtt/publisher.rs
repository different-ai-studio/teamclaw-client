use rumqttc::QoS;
use crate::proto::amux;
use super::MqttClient;

pub struct Publisher<'a> {
    client: &'a MqttClient,
}

impl<'a> Publisher<'a> {
    pub fn new(client: &'a MqttClient) -> Self {
        Self { client }
    }

    pub async fn publish_peer_list(&self, list: &amux::PeerList) -> Result<(), rumqttc::ClientError> {
        self.client.client
            .publish(self.client.topics.peers(), QoS::AtLeastOnce, true, list.encode_to_vec())
            .await
    }

    pub async fn publish_agent_event(&self, agent_id: &str, envelope: &amux::Envelope) -> Result<(), rumqttc::ClientError> {
        self.client.client
            .publish(self.client.topics.agent_events(agent_id), QoS::AtLeastOnce, false, envelope.encode_to_vec())
            .await
    }

    /// Dual-publishes RuntimeInfo to BOTH the legacy agent/{id}/state and
    /// the new runtime/{id}/state retained topics during the Phase 1-2
    /// compat window. Phase 3 drops the legacy publish.
    pub async fn publish_agent_state(&self, agent_id: &str, info: &amux::RuntimeInfo) -> Result<(), rumqttc::ClientError> {
        let payload = info.encode_to_vec();
        self.client.client
            .publish(self.client.topics.agent_state(agent_id), QoS::AtLeastOnce, true, payload.clone())
            .await?;
        self.client.client
            .publish(self.client.topics.runtime_state(agent_id), QoS::AtLeastOnce, true, payload)
            .await
    }

    /// Clears retained state on BOTH the legacy agent/{id}/state and the
    /// new runtime/{id}/state paths. Otherwise a legacy subscriber or a
    /// new subscriber would see ghost state after runtime termination.
    pub async fn clear_agent_state(&self, agent_id: &str) -> Result<(), rumqttc::ClientError> {
        self.client.client
            .publish(self.client.topics.agent_state(agent_id), QoS::AtLeastOnce, true, Vec::<u8>::new())
            .await?;
        self.client.client
            .publish(self.client.topics.runtime_state(agent_id), QoS::AtLeastOnce, true, Vec::<u8>::new())
            .await
    }

    pub async fn publish_device_collab_event(&self, event: &amux::DeviceCollabEvent) -> Result<(), rumqttc::ClientError> {
        self.client.client
            .publish(self.client.topics.collab(), QoS::AtLeastOnce, false, event.encode_to_vec())
            .await
    }

    pub async fn publish_device_collab_event_to(&self, device_id: &str, event: &amux::DeviceCollabEvent) -> Result<(), rumqttc::ClientError> {
        self.client.client
            .publish(self.client.topics.collab_for(device_id), QoS::AtLeastOnce, false, event.encode_to_vec())
            .await
    }

    pub async fn publish_workspace_list(&self, list: &amux::WorkspaceList) -> Result<(), rumqttc::ClientError> {
        self.client.client
            .publish(self.client.topics.workspaces(), QoS::AtLeastOnce, true, list.encode_to_vec())
            .await
    }
}
