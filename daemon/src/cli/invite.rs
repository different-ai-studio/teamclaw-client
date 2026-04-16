use uuid::Uuid;
use crate::config::{DaemonConfig, MemberStore, PendingInvite};

pub fn run_invite(name: &str, expires_hours: u32, is_owner: bool) -> anyhow::Result<()> {
    let config = DaemonConfig::load(&DaemonConfig::default_path())?;
    let mut store = MemberStore::load(&MemberStore::default_path())?;

    let invite_token = Uuid::new_v4().to_string();
    let expires_at = if is_owner {
        chrono::DateTime::parse_from_rfc3339("2099-12-31T23:59:59Z")
            .unwrap().with_timezone(&chrono::Utc)
    } else {
        chrono::Utc::now() + chrono::Duration::hours(expires_hours as i64)
    };

    let invite = PendingInvite {
        invite_token: invite_token.clone(),
        display_name: name.into(),
        created_at: chrono::Utc::now(),
        expires_at,
        role: if is_owner { "owner".into() } else { "member".into() },
    };
    store.add_invite(invite);
    store.save(&MemberStore::default_path())?;

    let deeplink = format!(
        "amux://join?broker={}&device={}&token={}&username={}&password={}",
        config.mqtt.broker_url, config.device.id, invite_token,
        config.mqtt.username, config.mqtt.password
    );

    if is_owner {
        println!("Owner pairing code for \"{}\":", name);
    } else {
        println!("Invite for \"{}\" (expires in {}h):", name, expires_hours);
    }
    print_qr(&deeplink);
    println!("Deeplink: {}", deeplink);

    Ok(())
}

fn print_qr(data: &str) {
    use qrcode::QrCode;
    if let Ok(code) = QrCode::new(data.as_bytes()) {
        let string = code.render::<char>().quiet_zone(false).module_dimensions(2, 1).build();
        println!("{}", string);
    } else {
        println!("[QR generation failed — use deeplink below]");
    }
}
