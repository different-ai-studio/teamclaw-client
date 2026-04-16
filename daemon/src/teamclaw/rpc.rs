use crate::proto::teamclaw::{RpcRequest, RpcResponse};
use prost::Message as ProstMessage;
use rumqttc::{AsyncClient, QoS};
use std::collections::HashMap;
use tokio::sync::oneshot;
use uuid::Uuid;

/// Server-side RPC handler: receives requests and sends responses.
pub struct RpcServer {
    pub client: AsyncClient,
    pub team_id: String,
    pub device_id: String,
}

impl RpcServer {
    pub fn new(client: AsyncClient, team_id: String, device_id: String) -> Self {
        Self { client, team_id, device_id }
    }

    /// Parses an MQTT topic and payload into a (request_id, RpcRequest) pair.
    ///
    /// Expected topic format: `teamclaw/{teamId}/rpc/{targetDeviceId}/{requestId}/req`
    pub fn parse_request(topic: &str, payload: &[u8]) -> Option<(String, RpcRequest)> {
        // Split topic and extract request_id from position 4
        let parts: Vec<&str> = topic.split('/').collect();
        // teamclaw / {teamId} / rpc / {targetDeviceId} / {requestId} / req
        if parts.len() != 6 {
            return None;
        }
        if parts[0] != "teamclaw" || parts[2] != "rpc" || parts[5] != "req" {
            return None;
        }
        let request_id = parts[4].to_string();
        let request = RpcRequest::decode(payload).ok()?;
        Some((request_id, request))
    }

    /// Publishes an RPC response back to the sender's device.
    ///
    /// Response topic: `teamclaw/{teamId}/rpc/{senderDeviceId}/{requestId}/res`
    pub async fn respond(
        &self,
        request: &RpcRequest,
        request_id: &str,
        response: RpcResponse,
    ) {
        let topic = format!(
            "teamclaw/{}/rpc/{}/{}/res",
            self.team_id, request.sender_device_id, request_id
        );
        let payload = response.encode_to_vec();
        if let Err(e) = self.client.publish(topic, QoS::AtLeastOnce, false, payload).await {
            tracing::warn!("RpcServer: failed to publish response: {e}");
        }
    }
}

/// Client-side RPC handler: sends requests and waits for responses via oneshot channels.
pub struct RpcClient {
    pub client: AsyncClient,
    pub team_id: String,
    pub device_id: String,
    pub pending: HashMap<String, oneshot::Sender<RpcResponse>>,
}

impl RpcClient {
    pub fn new(client: AsyncClient, team_id: String, device_id: String) -> Self {
        Self {
            client,
            team_id,
            device_id,
            pending: HashMap::new(),
        }
    }

    /// Sends an RPC request to `target_device_id` and returns a receiver for the response.
    pub async fn request(
        &mut self,
        target_device_id: &str,
        request: RpcRequest,
    ) -> crate::error::Result<oneshot::Receiver<RpcResponse>> {
        let request_id = Self::new_request_id();
        let topic = format!(
            "teamclaw/{}/rpc/{}/{}/req",
            self.team_id, target_device_id, request_id
        );
        let payload = request.encode_to_vec();
        let (tx, rx) = oneshot::channel();
        self.pending.insert(request_id.clone(), tx);
        self.client.publish(topic, QoS::AtLeastOnce, false, payload).await?;
        Ok(rx)
    }

    /// Handles an incoming response topic+payload. Returns `true` if it matched a pending request.
    ///
    /// Expected topic format: `teamclaw/{teamId}/rpc/{deviceId}/{requestId}/res`
    pub fn handle_response(&mut self, topic: &str, payload: &[u8]) -> bool {
        let parts: Vec<&str> = topic.split('/').collect();
        // teamclaw / {teamId} / rpc / {deviceId} / {requestId} / res
        if parts.len() != 6 {
            return false;
        }
        if parts[0] != "teamclaw" || parts[2] != "rpc" || parts[5] != "res" {
            return false;
        }
        let request_id = parts[4];
        if let Some(tx) = self.pending.remove(request_id) {
            if let Ok(response) = RpcResponse::decode(payload) {
                let _ = tx.send(response);
                return true;
            }
        }
        false
    }

    /// Generates an 8-character request ID from a UUID.
    pub fn new_request_id() -> String {
        Uuid::new_v4().to_string()[..8].to_string()
    }
}
