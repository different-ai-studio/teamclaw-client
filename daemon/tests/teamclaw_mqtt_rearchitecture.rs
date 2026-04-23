#[path = "../src/teamclaw/topics.rs"]
mod topics;
#[path = "../src/mqtt/subscriber.rs"]
mod subscriber;

mod proto {
    pub mod amux {
        include!(concat!(env!("OUT_DIR"), "/amux.rs"));
    }
}

use topics::TeamclawTopics;

#[test]
fn builds_new_device_and_live_topics() {
    let topics = TeamclawTopics::new("team1", "dev-a");

    assert_eq!(topics.device_rpc_req(), "amux/team1/device/dev-a/rpc/req");
    assert_eq!(topics.device_rpc_res(), "amux/team1/device/dev-a/rpc/res");
    assert_eq!(topics.device_notify(), "amux/team1/device/dev-a/notify");
    assert_eq!(topics.session_live("sess-1"), "amux/team1/session/sess-1/live");
}

#[tokio::test]
async fn parse_session_live_and_device_notify_topics() {
    let live = rumqttc::Publish::new(
        "amux/team1/session/sess-1/live",
        rumqttc::QoS::AtLeastOnce,
        vec![1, 2, 3],
    );
    let notify = rumqttc::Publish::new(
        "amux/team1/device/dev-a/notify",
        rumqttc::QoS::AtLeastOnce,
        vec![4, 5, 6],
    );

    assert!(matches!(
        subscriber::parse_incoming(&live),
        Some(subscriber::IncomingMessage::TeamclawSessionLive { .. })
    ));
    assert!(matches!(
        subscriber::parse_incoming(&notify),
        Some(subscriber::IncomingMessage::TeamclawNotify { .. })
    ));
}

#[test]
fn parse_global_tasks_topic() {
    let global_tasks = rumqttc::Publish::new(
        "amux/team1/tasks",
        rumqttc::QoS::AtLeastOnce,
        vec![7, 8, 9],
    );

    assert!(matches!(
        subscriber::parse_incoming(&global_tasks),
        Some(subscriber::IncomingMessage::TeamclawTaskEvent { session_id, .. }) if session_id.is_empty()
    ));
}
