#[path = "../src/teamclaw/topics.rs"]
mod topics;

use topics::TeamclawTopics;

#[test]
fn builds_new_device_and_live_topics() {
    let topics = TeamclawTopics::new("team1", "dev-a");

    assert_eq!(topics.device_rpc_req(), "amux/team1/device/dev-a/rpc/req");
    assert_eq!(topics.device_rpc_res(), "amux/team1/device/dev-a/rpc/res");
    assert_eq!(topics.device_notify(), "amux/team1/device/dev-a/notify");
    assert_eq!(topics.session_live("sess-1"), "amux/team1/session/sess-1/live");
}
