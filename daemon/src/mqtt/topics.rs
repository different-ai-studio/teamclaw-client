/// Builds MQTT topic paths for a given device.
pub struct Topics {
    device_id: String,
}

impl Topics {
    pub fn new(device_id: &str) -> Self {
        Self {
            device_id: device_id.to_string(),
        }
    }

    pub fn status(&self) -> String {
        format!("amux/{}/status", self.device_id)
    }

    pub fn agents(&self) -> String {
        format!("amux/{}/agents", self.device_id)
    }

    pub fn peers(&self) -> String {
        format!("amux/{}/peers", self.device_id)
    }

    pub fn members(&self) -> String {
        format!("amux/{}/members", self.device_id)
    }

    pub fn workspaces(&self) -> String {
        format!("amux/{}/workspaces", self.device_id)
    }

    pub fn collab(&self) -> String {
        format!("amux/{}/collab", self.device_id)
    }

    pub fn agent_state(&self, agent_id: &str) -> String {
        format!("amux/{}/agent/{}/state", self.device_id, agent_id)
    }

    pub fn agent_events(&self, agent_id: &str) -> String {
        format!("amux/{}/agent/{}/events", self.device_id, agent_id)
    }

    pub fn agent_commands(&self, agent_id: &str) -> String {
        format!("amux/{}/agent/{}/commands", self.device_id, agent_id)
    }

    pub fn all_agent_commands(&self) -> String {
        format!("amux/{}/agent/+/commands", self.device_id)
    }
}
