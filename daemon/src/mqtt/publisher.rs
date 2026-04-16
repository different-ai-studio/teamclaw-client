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

    pub async fn publish_agent_list(&self, list: &amux::AgentList) -> Result<(), rumqttc::ClientError> {
        self.client.client
            .publish(self.client.topics.agents(), QoS::AtLeastOnce, true, list.encode_to_vec())
            .await
    }

    pub async fn publish_peer_list(&self, list: &amux::PeerList) -> Result<(), rumqttc::ClientError> {
        self.client.client
            .publish(self.client.topics.peers(), QoS::AtLeastOnce, true, list.encode_to_vec())
            .await
    }

    pub async fn publish_member_list(&self, list: &amux::MemberList) -> Result<(), rumqttc::ClientError> {
        self.client.client
            .publish(self.client.topics.members(), QoS::AtLeastOnce, true, list.encode_to_vec())
            .await
    }

    pub async fn publish_agent_event(&self, agent_id: &str, envelope: &amux::Envelope) -> Result<(), rumqttc::ClientError> {
        self.client.client
            .publish(self.client.topics.agent_events(agent_id), QoS::AtLeastOnce, false, envelope.encode_to_vec())
            .await
    }

    pub async fn publish_agent_state(&self, agent_id: &str, info: &amux::AgentInfo) -> Result<(), rumqttc::ClientError> {
        self.client.client
            .publish(self.client.topics.agent_state(agent_id), QoS::AtLeastOnce, true, info.encode_to_vec())
            .await
    }

    pub async fn publish_device_collab_event(&self, event: &amux::DeviceCollabEvent) -> Result<(), rumqttc::ClientError> {
        self.client.client
            .publish(self.client.topics.collab(), QoS::AtLeastOnce, false, event.encode_to_vec())
            .await
    }

    pub async fn publish_workspace_list(&self, list: &amux::WorkspaceList) -> Result<(), rumqttc::ClientError> {
        self.client.client
            .publish(self.client.topics.workspaces(), QoS::AtLeastOnce, true, list.encode_to_vec())
            .await
    }
}
