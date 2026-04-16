/// MQTT topic builder for the teamclaw collaboration namespace.
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

    // Team-level
    pub fn members(&self) -> String {
        format!("teamclaw/{}/members", self.team_id)
    }

    pub fn sessions(&self) -> String {
        format!("teamclaw/{}/sessions", self.team_id)
    }

    // Session-level
    pub fn session_messages(&self, session_id: &str) -> String {
        format!("teamclaw/{}/session/{}/messages", self.team_id, session_id)
    }

    pub fn session_meta(&self, session_id: &str) -> String {
        format!("teamclaw/{}/session/{}/meta", self.team_id, session_id)
    }

    pub fn session_presence(&self, session_id: &str) -> String {
        format!("teamclaw/{}/session/{}/presence", self.team_id, session_id)
    }

    pub fn session_workitems(&self, session_id: &str) -> String {
        format!("teamclaw/{}/session/{}/workitems", self.team_id, session_id)
    }

    // User-level
    pub fn user_invites(&self, user_id: &str) -> String {
        format!("teamclaw/{}/user/{}/invites", self.team_id, user_id)
    }

    // RPC
    pub fn rpc_request(&self, target_device_id: &str, request_id: &str) -> String {
        format!("teamclaw/{}/rpc/{}/{}/req", self.team_id, target_device_id, request_id)
    }

    pub fn rpc_response(&self, target_device_id: &str, request_id: &str) -> String {
        format!("teamclaw/{}/rpc/{}/{}/res", self.team_id, target_device_id, request_id)
    }

    /// Subscribe pattern for incoming RPC requests targeted at this device.
    pub fn rpc_incoming_requests(&self) -> String {
        format!("teamclaw/{}/rpc/{}/+/req", self.team_id, self.device_id)
    }

    /// Subscribe pattern for all session messages (wildcard).
    pub fn all_session_messages(&self) -> String {
        format!("teamclaw/{}/session/+/messages", self.team_id)
    }

    /// Subscribe pattern for all session metadata (wildcard).
    pub fn all_session_meta(&self) -> String {
        format!("teamclaw/{}/session/+/meta", self.team_id)
    }

    /// Subscribe pattern for all work item events (wildcard).
    pub fn all_session_workitems(&self) -> String {
        format!("teamclaw/{}/session/+/workitems", self.team_id)
    }
}
