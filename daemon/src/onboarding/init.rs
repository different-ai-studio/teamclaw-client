use crate::onboarding::invite_url;
use crate::supabase::error::SupabaseResult;
use crate::supabase::{SupabaseClient, SupabaseConfig};
use std::path::{Path, PathBuf};

pub struct InitOutcome {
    pub agent_id: String,
    pub team_id: String,
    pub config_path: PathBuf,
}

/// Execute the `amuxd init <url>` flow against Supabase:
/// parse the join URL, claim the invite, log in with the returned one-time
/// credentials, and persist the refresh token + identity to disk.
pub async fn run(raw_url: &str, config_path: Option<&Path>) -> SupabaseResult<InitOutcome> {
    let invite = invite_url::parse(raw_url)?;

    // Placeholder cfg: the client only needs url+anon_key until login succeeds.
    let placeholder = SupabaseConfig {
        url: invite.url.clone(),
        anon_key: invite.anon_key.clone(),
        refresh_token: String::new(),
        team_id: String::new(),
        actor_id: String::new(),
    };
    let mut client = SupabaseClient::new(placeholder)?;
    let claim = client.claim_daemon_invite(invite.token).await?;
    client
        .login_with_password(&claim.auth_email, &claim.auth_password)
        .await?;

    let cfg = SupabaseConfig {
        url: invite.url,
        anon_key: invite.anon_key,
        refresh_token: client.config().refresh_token.clone(),
        team_id: claim.team_id.clone(),
        actor_id: claim.agent_id.clone(),
    };
    let path = match config_path {
        Some(p) => p.to_path_buf(),
        None => SupabaseConfig::default_path()?,
    };
    cfg.save(&path)?;

    Ok(InitOutcome {
        agent_id: claim.agent_id,
        team_id: claim.team_id,
        config_path: path,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;
    use wiremock::matchers::{method, path_regex};
    use wiremock::{Mock, MockServer, ResponseTemplate};

    #[tokio::test]
    async fn writes_config_after_successful_claim() {
        let srv = MockServer::start().await;

        Mock::given(method("POST"))
            .and(path_regex(r"^/rest/v1/rpc/claim_daemon_invite$"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!([
                {
                    "agent_id": "agent-uuid",
                    "team_id": "team-uuid",
                    "auth_email": "daemon+agent-uuid@amux.local",
                    "auth_password": "pw"
                }
            ])))
            .mount(&srv)
            .await;

        Mock::given(method("POST"))
            .and(path_regex(r"^/auth/v1/token$"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "access_token": "at",
                "expires_in": 3600,
                "refresh_token": "rt-final"
            })))
            .mount(&srv)
            .await;

        let url = format!(
            "amux://join?token=9f6b6e53-8d4e-4f7a-9f58-d9d1c7b2e8a5\
             &url={}&anon=anon",
            urlencode(&srv.uri())
        );
        let dir = tempdir().unwrap();
        let cfg_path = dir.path().join("supabase.toml");

        let outcome = run(&url, Some(&cfg_path)).await.unwrap();
        assert_eq!(outcome.agent_id, "agent-uuid");
        assert_eq!(outcome.team_id, "team-uuid");
        let saved = SupabaseConfig::load(&cfg_path).unwrap();
        assert_eq!(saved.refresh_token, "rt-final");
        assert_eq!(saved.team_id, "team-uuid");
        assert_eq!(saved.actor_id, "agent-uuid");
    }

    fn urlencode(s: &str) -> String {
        s.replace(':', "%3A").replace('/', "%2F")
    }
}
