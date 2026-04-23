/// MQTT topic builder for team-scoped collaboration topics.
pub struct TeamclawTopics {
    pub team_id: String,
    pub device_id: String,
}

impl TeamclawTopics {
    pub fn new(team_id: &str, device_id: &str) -> Self {
        Self {
            team_id: team_id.to_string(),
            device_id: device_id.to_string(),
        }
    }

    fn base(&self) -> String {
        format!("amux/{}", self.team_id)
    }

    // RPC
    pub fn device_rpc_req(&self) -> String {
        format!("{}/device/{}/rpc/req", self.base(), self.device_id)
    }

    /// Fixed device-scoped response channel for the MQTT rearchitecture.
    pub fn device_rpc_res(&self) -> String {
        format!("{}/device/{}/rpc/res", self.base(), self.device_id)
    }

    /// Targeted device notification channel used to invalidate local state.
    pub fn device_notify(&self) -> String {
        format!("{}/device/{}/notify", self.base(), self.device_id)
    }

    /// Single realtime stream for live session events in the new contract.
    pub fn session_live(&self, session_id: &str) -> String {
        format!("{}/session/{}/live", self.base(), session_id)
    }

}

#[cfg(test)]
mod tests {
    use super::*;

    fn test_rpc_topics() {
        let t = TeamclawTopics::new("team1", "dev-a");
        assert_eq!(t.device_rpc_req(), "amux/team1/device/dev-a/rpc/req");
        assert_eq!(t.device_rpc_res(), "amux/team1/device/dev-a/rpc/res");
    }

    #[test]
    fn test_live_and_notify_topics() {
        let t = TeamclawTopics::new("team1", "dev-a");
        assert_eq!(t.device_notify(), "amux/team1/device/dev-a/notify");
        assert_eq!(t.session_live("s1"), "amux/team1/session/s1/live");
    }
}
