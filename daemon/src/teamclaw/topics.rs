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

    // Team-level
    pub fn sessions(&self) -> String {
        format!("{}/sessions", self.base())
    }

    // Session-level
    pub fn session_messages(&self, session_id: &str) -> String {
        format!("{}/session/{}/messages", self.base(), session_id)
    }

    pub fn actor_session_meta(&self, actor_id: &str, session_id: &str) -> String {
        format!("{}/actor/{}/session/{}/meta", self.base(), actor_id, session_id)
    }

    pub fn session_presence(&self, session_id: &str) -> String {
        format!("{}/session/{}/presence", self.base(), session_id)
    }

    pub fn session_tasks(&self, session_id: &str) -> String {
        format!("{}/session/{}/tasks", self.base(), session_id)
    }

    /// Global tasks topic (not tied to a session)
    pub fn tasks(&self) -> String {
        format!("{}/tasks", self.base())
    }

    // User-level
    pub fn user_invites(&self, user_id: &str) -> String {
        format!("{}/user/{}/invites", self.base(), user_id)
    }

    // RPC
    pub fn rpc_request(&self, target_device_id: &str, request_id: &str) -> String {
        format!("{}/device/{}/rpc/{}/req", self.base(), target_device_id, request_id)
    }

    pub fn rpc_response(&self, target_device_id: &str, request_id: &str) -> String {
        format!("{}/device/{}/rpc/{}/res", self.base(), target_device_id, request_id)
    }

    /// Subscribe pattern for incoming RPC requests targeted at this device.
    pub fn rpc_incoming_requests(&self) -> String {
        format!("{}/device/{}/rpc/+/req", self.base(), self.device_id)
    }

    /// Subscribe pattern for all session messages (wildcard).
    pub fn all_session_messages(&self) -> String {
        format!("{}/session/+/messages", self.base())
    }

    /// Subscribe pattern for all session metadata addressed to one actor.
    pub fn actor_session_meta_wildcard(&self, actor_id: &str) -> String {
        format!("{}/actor/{}/session/+/meta", self.base(), actor_id)
    }

    /// Subscribe pattern for all task events (wildcard).
    pub fn all_session_tasks(&self) -> String {
        format!("{}/session/+/tasks", self.base())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_team_level_topics() {
        let t = TeamclawTopics::new("team1", "dev-a");
        assert_eq!(t.sessions(), "amux/team1/sessions");
    }

    #[test]
    fn test_session_level_topics() {
        let t = TeamclawTopics::new("team1", "dev-a");
        assert_eq!(t.session_messages("s1"), "amux/team1/session/s1/messages");
        assert_eq!(t.actor_session_meta("actor1", "s1"), "amux/team1/actor/actor1/session/s1/meta");
        assert_eq!(t.session_presence("s1"), "amux/team1/session/s1/presence");
        assert_eq!(t.session_tasks("s1"), "amux/team1/session/s1/tasks");
    }

    #[test]
    fn test_user_level_topics() {
        let t = TeamclawTopics::new("team1", "dev-a");
        assert_eq!(t.user_invites("user1"), "amux/team1/user/user1/invites");
    }

    #[test]
    fn test_rpc_topics() {
        let t = TeamclawTopics::new("team1", "dev-a");
        assert_eq!(t.rpc_request("dev-b", "req123"), "amux/team1/device/dev-b/rpc/req123/req");
        assert_eq!(t.rpc_response("dev-b", "req123"), "amux/team1/device/dev-b/rpc/req123/res");
    }

    #[test]
    fn test_wildcard_patterns() {
        let t = TeamclawTopics::new("team1", "dev-a");
        assert_eq!(t.rpc_incoming_requests(), "amux/team1/device/dev-a/rpc/+/req");
        assert_eq!(t.all_session_messages(), "amux/team1/session/+/messages");
        assert_eq!(t.actor_session_meta_wildcard("actor1"), "amux/team1/actor/actor1/session/+/meta");
        assert_eq!(t.all_session_tasks(), "amux/team1/session/+/tasks");
    }
}
