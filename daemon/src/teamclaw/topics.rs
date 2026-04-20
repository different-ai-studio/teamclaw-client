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

    pub fn session_tasks(&self, session_id: &str) -> String {
        format!("teamclaw/{}/session/{}/tasks", self.team_id, session_id)
    }

    /// Global tasks topic (not tied to a session)
    pub fn tasks(&self) -> String {
        format!("teamclaw/{}/tasks", self.team_id)
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

    /// Subscribe pattern for all task events (wildcard).
    pub fn all_session_tasks(&self) -> String {
        format!("teamclaw/{}/session/+/tasks", self.team_id)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_team_level_topics() {
        let t = TeamclawTopics::new("team1", "dev-a");
        assert_eq!(t.members(), "teamclaw/team1/members");
        assert_eq!(t.sessions(), "teamclaw/team1/sessions");
    }

    #[test]
    fn test_session_level_topics() {
        let t = TeamclawTopics::new("team1", "dev-a");
        assert_eq!(t.session_messages("s1"), "teamclaw/team1/session/s1/messages");
        assert_eq!(t.session_meta("s1"), "teamclaw/team1/session/s1/meta");
        assert_eq!(t.session_presence("s1"), "teamclaw/team1/session/s1/presence");
        assert_eq!(t.session_tasks("s1"), "teamclaw/team1/session/s1/tasks");
    }

    #[test]
    fn test_user_level_topics() {
        let t = TeamclawTopics::new("team1", "dev-a");
        assert_eq!(t.user_invites("user1"), "teamclaw/team1/user/user1/invites");
    }

    #[test]
    fn test_rpc_topics() {
        let t = TeamclawTopics::new("team1", "dev-a");
        assert_eq!(t.rpc_request("dev-b", "req123"), "teamclaw/team1/rpc/dev-b/req123/req");
        assert_eq!(t.rpc_response("dev-b", "req123"), "teamclaw/team1/rpc/dev-b/req123/res");
    }

    #[test]
    fn test_wildcard_patterns() {
        let t = TeamclawTopics::new("team1", "dev-a");
        assert_eq!(t.rpc_incoming_requests(), "teamclaw/team1/rpc/dev-a/+/req");
        assert_eq!(t.all_session_messages(), "teamclaw/team1/session/+/messages");
        assert_eq!(t.all_session_meta(), "teamclaw/team1/session/+/meta");
        assert_eq!(t.all_session_tasks(), "teamclaw/team1/session/+/tasks");
    }
}
