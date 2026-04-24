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

    // ─── Teamclaw (absorbed from teamclaw/topics.rs in Phase 1a) ───

    pub fn device_rpc_req(&self) -> String {
        format!("{}/rpc/req", self.device_base())
    }

    pub fn device_rpc_res(&self) -> String {
        format!("{}/rpc/res", self.device_base())
    }

    pub fn device_notify(&self) -> String {
        format!("{}/notify", self.device_base())
    }

    pub fn session_live(&self, session_id: &str) -> String {
        format!("amux/{}/session/{}/live", self.team_id, session_id)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn absorbed_rpc_paths() {
        let t = Topics::new("team1", "dev-a");
        assert_eq!(t.device_rpc_req(), "amux/team1/device/dev-a/rpc/req");
        assert_eq!(t.device_rpc_res(), "amux/team1/device/dev-a/rpc/res");
    }

    #[test]
    fn absorbed_notify_and_session_live() {
        let t = Topics::new("team1", "dev-a");
        assert_eq!(t.device_notify(), "amux/team1/device/dev-a/notify");
        assert_eq!(t.session_live("s1"), "amux/team1/session/s1/live");
    }
}
