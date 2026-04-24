/// Builds MQTT topic paths for a given team-scoped device namespace.
pub struct Topics {
    team_id: String,
    device_id: String,
}

impl Topics {
    pub fn new(team_id: &str, device_id: &str) -> Self {
        Self {
            team_id: team_id.to_string(),
            device_id: device_id.to_string(),
        }
    }

    fn device_base(&self) -> String {
        format!("amux/{}/device/{}", self.team_id, self.device_id)
    }

    pub fn status(&self) -> String {
        format!("{}/status", self.device_base())
    }

    pub fn peers(&self) -> String {
        format!("{}/peers", self.device_base())
    }

    pub fn workspaces(&self) -> String {
        format!("{}/workspaces", self.device_base())
    }

    pub fn collab(&self) -> String {
        format!("{}/collab", self.device_base())
    }

    pub fn collab_for(&self, device_id: &str) -> String {
        format!("amux/{}/device/{}/collab", self.team_id, device_id)
    }

    pub fn agent_state(&self, agent_id: &str) -> String {
        format!("{}/agent/{}/state", self.device_base(), agent_id)
    }

    pub fn agent_events(&self, agent_id: &str) -> String {
        format!("{}/agent/{}/events", self.device_base(), agent_id)
    }

    pub fn agent_commands(&self, agent_id: &str) -> String {
        format!("{}/agent/{}/commands", self.device_base(), agent_id)
    }

    pub fn all_agent_commands(&self) -> String {
        format!("{}/agent/+/commands", self.device_base())
    }
}
