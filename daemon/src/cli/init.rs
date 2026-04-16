use uuid::Uuid;
use crate::config::{DaemonConfig, DeviceConfig, MqttConfig, AgentsConfig, MemberStore, StoredMember};

pub fn run_init() -> anyhow::Result<()> {
    let config_path = DaemonConfig::default_path();
    if config_path.exists() {
        println!("Config already exists at {}", config_path.display());
        println!("Delete it first if you want to re-initialize.");
        return Ok(());
    }

    println!("amuxd init — first-time setup\n");

    let device_name = prompt("Device name")?;
    let broker_url = prompt("MQTT broker URL")?;
    let username = prompt("MQTT username")?;
    let password = prompt("MQTT password")?;

    let device_id = Uuid::new_v4().to_string();

    let config = DaemonConfig {
        device: DeviceConfig { id: device_id.clone(), name: device_name.clone() },
        mqtt: MqttConfig { broker_url: broker_url.clone(), username, password },
        agents: AgentsConfig::default(),
    };
    config.save(&config_path)?;
    println!("✓ Config written to {}", config_path.display());

    let owner_token = Uuid::new_v4().to_string();
    let mut store = MemberStore::load(&MemberStore::default_path())?;
    store.add_member(StoredMember {
        member_id: Uuid::new_v4().to_string(),
        display_name: device_name,
        role: "owner".into(),
        token: owner_token.clone(),
        joined_at: chrono::Utc::now(),
    });
    store.save(&MemberStore::default_path())?;
    println!("✓ Owner registered in {}\n", MemberStore::default_path().display());

    let deeplink = format!("amux://join?broker={}&device={}&token={}&username={}&password={}", broker_url, device_id, owner_token, config.mqtt.username, config.mqtt.password);
    println!("Scan this QR code with the AMUX app to connect as owner:");
    print_qr(&deeplink);
    println!("Deeplink: {}", deeplink);

    Ok(())
}

fn prompt(label: &str) -> anyhow::Result<String> {
    use std::io::Write;
    print!("{}: ", label);
    std::io::stdout().flush()?;
    let mut input = String::new();
    std::io::stdin().read_line(&mut input)?;
    Ok(input.trim().to_string())
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
