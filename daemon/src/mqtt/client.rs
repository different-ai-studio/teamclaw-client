use rumqttc::{AsyncClient, EventLoop, MqttOptions, QoS, Transport, TlsConfiguration};
use std::sync::Arc;
use std::time::Duration;
use tracing::info;

use crate::config::DaemonConfig;
use crate::proto::amux::DeviceState;
use prost::Message;

use super::Topics;

pub struct MqttClient {
    pub client: AsyncClient,
    pub eventloop: EventLoop,
    pub topics: Topics,
}

/// Danger: accepts any TLS certificate (for self-signed brokers)
pub mod client_danger {
    use rustls::client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier};
    use rustls::pki_types::{CertificateDer, ServerName, UnixTime};
    use rustls::{DigitallySignedStruct, Error, SignatureScheme};

    #[derive(Debug)]
    pub struct NoCertVerifier;

    impl ServerCertVerifier for NoCertVerifier {
        fn verify_server_cert(
            &self, _end_entity: &CertificateDer<'_>, _intermediates: &[CertificateDer<'_>],
            _server_name: &ServerName<'_>, _ocsp_response: &[u8], _now: UnixTime,
        ) -> Result<ServerCertVerified, Error> {
            Ok(ServerCertVerified::assertion())
        }

        fn verify_tls12_signature(
            &self, _message: &[u8], _cert: &CertificateDer<'_>, _dss: &DigitallySignedStruct,
        ) -> Result<HandshakeSignatureValid, Error> {
            Ok(HandshakeSignatureValid::assertion())
        }

        fn verify_tls13_signature(
            &self, _message: &[u8], _cert: &CertificateDer<'_>, _dss: &DigitallySignedStruct,
        ) -> Result<HandshakeSignatureValid, Error> {
            Ok(HandshakeSignatureValid::assertion())
        }

        fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
            rustls::crypto::ring::default_provider()
                .signature_verification_algorithms
                .supported_schemes()
        }
    }
}

impl MqttClient {
    pub fn new(config: &DaemonConfig) -> crate::error::Result<Self> {
        let client_id = format!("amuxd-{}", &config.device.id[..8.min(config.device.id.len())]);

        // Parse host, port, TLS from broker_url
        let use_tls = config.mqtt.broker_url.starts_with("mqtts://");
        let host_port = config.mqtt.broker_url
            .trim_start_matches("mqtts://")
            .trim_start_matches("mqtt://");
        let (host, port) = if let Some((h, p)) = host_port.split_once(':') {
            (h.to_string(), p.parse::<u16>().unwrap_or(if use_tls { 8883 } else { 1883 }))
        } else {
            (host_port.to_string(), if use_tls { 8883 } else { 1883 })
        };

        let mut opts = MqttOptions::new(&client_id, &host, port);
        opts.set_credentials(&config.mqtt.username, &config.mqtt.password);
        opts.set_keep_alive(Duration::from_secs(30));
        opts.set_clean_session(true);

        if use_tls {
            let mut tls_config = rustls::ClientConfig::builder()
                .dangerous()
                .with_custom_certificate_verifier(Arc::new(client_danger::NoCertVerifier))
                .with_no_client_auth();
            tls_config.alpn_protocols = vec![];

            opts.set_transport(Transport::tls_with_config(
                rumqttc::TlsConfiguration::Rustls(Arc::new(tls_config)),
            ));
        }

        // LWT: publish offline status if daemon disconnects unexpectedly
        let team_id = config.team_id.as_deref().unwrap_or("teamclaw");
        let topics = Topics::new(team_id, &config.device.id);
        let lwt_payload = DeviceState {
            online: false,
            device_name: config.device.name.clone(),
            timestamp: chrono::Utc::now().timestamp(),
        };
        // Phase 1a: LWT stays on device/{id}/status. /state is dual-published
        // for normal transitions but NOT LWT-backed in Phase 1-2. Phase 3
        // retargets LWT to /state when /status is retired.
        let lwt = rumqttc::LastWill::new(
            topics.status(),
            lwt_payload.encode_to_vec(),
            QoS::AtLeastOnce,
            true,
        );
        opts.set_last_will(lwt);

        let (client, eventloop) = AsyncClient::new(opts, 100);

        Ok(Self {
            client,
            eventloop,
            topics,
        })
    }

    pub async fn announce_online(&self, device_name: &str) -> Result<(), rumqttc::ClientError> {
        let status = DeviceState {
            online: true,
            device_name: device_name.into(),
            timestamp: chrono::Utc::now().timestamp(),
        };
        self.client
            .publish(
                self.topics.status(),
                QoS::AtLeastOnce,
                true,
                status.encode_to_vec(),
            )
            .await
    }

    pub async fn subscribe_all(&self) -> Result<(), rumqttc::ClientError> {
        self.client
            .subscribe(self.topics.runtime_commands_wildcard(), QoS::AtLeastOnce)
            .await?;
        info!(
            "subscribed to {}",
            self.topics.runtime_commands_wildcard(),
        );
        Ok(())
    }
}
