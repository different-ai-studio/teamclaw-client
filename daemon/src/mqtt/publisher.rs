use rumqttc::QoS;
use crate::proto::{amux, teamclaw};
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

    /// Dual-publishes Envelope to BOTH agent/{id}/events (legacy) and
    /// runtime/{id}/events during the Phase 1-2 compat window. Ephemeral;
    /// no retain.
    pub async fn publish_agent_event(&self, agent_id: &str, envelope: &amux::Envelope) -> Result<(), rumqttc::ClientError> {
        let payload = envelope.encode_to_vec();
        self.client.client
            .publish(self.client.topics.agent_events(agent_id), QoS::AtLeastOnce, false, payload.clone())
            .await?;
        self.client.client
            .publish(self.client.topics.runtime_events(agent_id), QoS::AtLeastOnce, false, payload)
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

    pub async fn publish_workspace_list(&self, list: &amux::WorkspaceList) -> Result<(), rumqttc::ClientError> {
        self.client.client
            .publish(self.client.topics.workspaces(), QoS::AtLeastOnce, true, list.encode_to_vec())
            .await
    }

    /// Publishes DeviceState (online/offline) to BOTH legacy /status and
    /// new /state retained topics. Used for normal online/offline
    /// transitions. LWT (crash path) still fires only on /status until
    /// Phase 3 retargets it.
    pub async fn publish_device_state(&self, state: &amux::DeviceState) -> Result<(), rumqttc::ClientError> {
        let payload = state.encode_to_vec();
        self.client.client
            .publish(self.client.topics.status(), QoS::AtLeastOnce, true, payload.clone())
            .await?;
        self.client.client
            .publish(self.client.topics.device_state(), QoS::AtLeastOnce, true, payload)
            .await
    }

    /// Publishes RuntimeInfo with state=FAILED and populated error fields
    /// to the retained runtime state topic (dual-publishes to agent/{id}/state
    /// + runtime/{id}/state per Phase 1a). The retain stays until a future
    /// clear — iOS surfaces the error_message to the user.
    pub async fn publish_runtime_failed(
        &self,
        runtime_id: &str,
        error_code: &str,
        error_message: &str,
        failed_stage: &str,
    ) -> Result<(), rumqttc::ClientError> {
        let info = crate::proto::amux::RuntimeInfo {
            runtime_id: runtime_id.to_string(),
            state: crate::proto::amux::RuntimeLifecycle::Failed as i32,
            error_code: error_code.to_string(),
            error_message: error_message.to_string(),
            failed_stage: failed_stage.to_string(),
            ..Default::default()
        };
        self.publish_agent_state(runtime_id, &info).await
    }

    /// Publishes a Notify hint to the daemon's own device/{id}/notify topic.
    /// Ephemeral (no retain) — receivers react by re-fetching authoritative
    /// state from Supabase or daemon RPC.
    pub async fn publish_notify(
        &self,
        event_type: &str,
        refresh_hint: &str,
    ) -> Result<(), rumqttc::ClientError> {
        let notify = teamclaw::Notify {
            event_type: event_type.to_string(),
            refresh_hint: refresh_hint.to_string(),
            sent_at: chrono::Utc::now().timestamp(),
        };
        self.client.client
            .publish(
                self.client.topics.device_notify(),
                QoS::AtLeastOnce,
                false,
                notify.encode_to_vec(),
            )
            .await
    }
}
