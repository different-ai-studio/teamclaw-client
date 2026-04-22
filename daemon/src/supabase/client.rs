use crate::supabase::config::SupabaseConfig;
use crate::supabase::error::{SupabaseError, SupabaseResult};
use reqwest::Client;
use serde::{Deserialize, Serialize};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

#[derive(Debug, Clone)]
pub struct SupabaseClient {
    http: Client,
    cfg: SupabaseConfig,
    state: Arc<Mutex<AuthState>>,
}

#[derive(Debug, Default)]
struct AuthState {
    access_token: Option<String>,
    refresh_token: String,
    expires_at: Option<Instant>,
}

#[derive(Debug, Deserialize)]
struct TokenResponse {
    access_token: String,
    expires_in: u64,
    refresh_token: String,
}

#[derive(Debug, Serialize)]
struct RefreshRequest<'a> {
    refresh_token: &'a str,
}

// Refresh while the access token still has >10 min of life left, so a single
// slow call won't expire mid-flight.
const REFRESH_SKEW: Duration = Duration::from_secs(10 * 60);

impl SupabaseClient {
    pub fn new(cfg: SupabaseConfig) -> SupabaseResult<Self> {
        let http = Client::builder()
            .timeout(Duration::from_secs(20))
            .build()?;
        let state = AuthState {
            refresh_token: cfg.refresh_token.clone(),
            ..Default::default()
        };
        Ok(Self {
            http,
            cfg,
            state: Arc::new(Mutex::new(state)),
        })
    }

    pub fn config(&self) -> &SupabaseConfig {
        &self.cfg
    }

    pub async fn access_token(&self) -> SupabaseResult<String> {
        {
            let st = self.state.lock().unwrap();
            if let (Some(tok), Some(exp)) = (&st.access_token, st.expires_at) {
                if exp > Instant::now() + REFRESH_SKEW {
                    return Ok(tok.clone());
                }
            }
        }
        self.refresh().await
    }

    async fn refresh(&self) -> SupabaseResult<String> {
        let rt = { self.state.lock().unwrap().refresh_token.clone() };
        let url = format!("{}/auth/v1/token?grant_type=refresh_token", self.cfg.url);
        let resp = self
            .http
            .post(&url)
            .header("apikey", &self.cfg.anon_key)
            .json(&RefreshRequest { refresh_token: &rt })
            .send()
            .await?;

        if !resp.status().is_success() {
            let text = resp.text().await.unwrap_or_default();
            return Err(SupabaseError::Auth(format!("refresh failed: {text}")));
        }
        let body: TokenResponse = resp.json().await?;

        let mut st = self.state.lock().unwrap();
        st.access_token = Some(body.access_token.clone());
        st.refresh_token = body.refresh_token;
        st.expires_at = Some(Instant::now() + Duration::from_secs(body.expires_in));
        Ok(body.access_token)
    }

    /// Trade an email/password for tokens. Used immediately after
    /// `claim_daemon_invite` returns the daemon's one-time credentials.
    pub async fn login_with_password(
        &mut self,
        email: &str,
        password: &str,
    ) -> SupabaseResult<String> {
        #[derive(Serialize)]
        struct Req<'a> {
            email: &'a str,
            password: &'a str,
        }
        let url = format!("{}/auth/v1/token?grant_type=password", self.cfg.url);
        let resp = self
            .http
            .post(&url)
            .header("apikey", &self.cfg.anon_key)
            .json(&Req { email, password })
            .send()
            .await?;
        if !resp.status().is_success() {
            let text = resp.text().await.unwrap_or_default();
            return Err(SupabaseError::Auth(format!("password login: {text}")));
        }
        let body: TokenResponse = resp.json().await?;
        let mut st = self.state.lock().unwrap();
        st.access_token = Some(body.access_token.clone());
        st.refresh_token = body.refresh_token.clone();
        st.expires_at = Some(Instant::now() + Duration::from_secs(body.expires_in));
        self.cfg.refresh_token = body.refresh_token.clone();
        Ok(body.access_token)
    }

    /// Call a PostgREST RPC function with the daemon's bearer token.
    pub async fn rpc<Req: Serialize, Resp: serde::de::DeserializeOwned>(
        &self,
        name: &str,
        payload: &Req,
    ) -> SupabaseResult<Resp> {
        let token = self.access_token().await?;
        let url = format!("{}/rest/v1/rpc/{name}", self.cfg.url);
        let resp = self
            .http
            .post(&url)
            .header("apikey", &self.cfg.anon_key)
            .bearer_auth(token)
            .json(payload)
            .send()
            .await?;
        if !resp.status().is_success() {
            let status = resp.status();
            let text = resp.text().await.unwrap_or_default();
            return Err(SupabaseError::Rpc {
                code: Some(status.as_u16().to_string()),
                message: text,
            });
        }
        Ok(resp.json().await?)
    }

    /// Anonymous RPC — used for `claim_daemon_invite`, where the invite token
    /// *is* the credential.
    pub async fn rpc_anon<Req: Serialize, Resp: serde::de::DeserializeOwned>(
        &self,
        name: &str,
        payload: &Req,
    ) -> SupabaseResult<Resp> {
        let url = format!("{}/rest/v1/rpc/{name}", self.cfg.url);
        let resp = self
            .http
            .post(&url)
            .header("apikey", &self.cfg.anon_key)
            .json(payload)
            .send()
            .await?;
        if !resp.status().is_success() {
            let status = resp.status();
            let text = resp.text().await.unwrap_or_default();
            return Err(SupabaseError::Rpc {
                code: Some(status.as_u16().to_string()),
                message: text,
            });
        }
        Ok(resp.json().await?)
    }

    /// Typed wrapper around the `claim_daemon_invite` RPC. Supabase's
    /// PostgREST always returns a set-returning function as an array, so we
    /// deserialize into `Vec<ClaimResult>` and pick the first row.
    pub async fn claim_daemon_invite(
        &self,
        token: uuid::Uuid,
    ) -> SupabaseResult<ClaimResult> {
        #[derive(Serialize)]
        struct Req {
            p_invite_token: uuid::Uuid,
        }
        let rows: Vec<ClaimResult> = self
            .rpc_anon("claim_daemon_invite", &Req { p_invite_token: token })
            .await?;
        rows.into_iter().next().ok_or(SupabaseError::InviteInvalid)
    }
}

#[derive(Debug, Deserialize)]
pub struct ClaimResult {
    pub agent_id: String,
    pub team_id: String,
    pub auth_email: String,
    pub auth_password: String,
}

#[cfg(test)]
mod tests {
    use super::*;
    use wiremock::matchers::{method, path_regex};
    use wiremock::{Mock, MockServer, ResponseTemplate};

    fn test_cfg(url: String) -> SupabaseConfig {
        SupabaseConfig {
            url,
            anon_key: "anon".into(),
            refresh_token: "rt-0".into(),
            team_id: "t".into(),
            actor_id: "a".into(),
        }
    }

    #[tokio::test]
    async fn refreshes_access_token_when_expired() {
        let srv = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path_regex(r"^/auth/v1/token$"))
            .respond_with(
                ResponseTemplate::new(200).set_body_json(serde_json::json!({
                    "access_token": "at-new",
                    "expires_in": 3600,
                    "refresh_token": "rt-1"
                })),
            )
            .mount(&srv)
            .await;

        let client = SupabaseClient::new(test_cfg(srv.uri())).unwrap();
        let tok = client.access_token().await.unwrap();
        assert_eq!(tok, "at-new");

        let tok2 = client.access_token().await.unwrap();
        assert_eq!(tok2, "at-new");
    }

    #[tokio::test]
    async fn refresh_failure_is_auth_error() {
        let srv = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path_regex(r"^/auth/v1/token$"))
            .respond_with(ResponseTemplate::new(400).set_body_string("bad"))
            .mount(&srv)
            .await;

        let client = SupabaseClient::new(test_cfg(srv.uri())).unwrap();
        match client.access_token().await {
            Err(SupabaseError::Auth(_)) => {}
            other => panic!("expected auth error, got {:?}", other),
        }
    }

    #[tokio::test]
    async fn rpc_posts_with_bearer_and_json() {
        let srv = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path_regex(r"^/auth/v1/token$"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "access_token": "at",
                "expires_in": 3600,
                "refresh_token": "rt"
            })))
            .mount(&srv)
            .await;
        Mock::given(method("POST"))
            .and(path_regex(r"^/rest/v1/rpc/echo$"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({"ok": true})))
            .mount(&srv)
            .await;

        let client = SupabaseClient::new(test_cfg(srv.uri())).unwrap();
        let body: serde_json::Value = client
            .rpc("echo", &serde_json::json!({"x": 1}))
            .await
            .unwrap();
        assert_eq!(body["ok"], true);
    }

    #[tokio::test]
    async fn rpc_anon_omits_bearer() {
        let srv = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path_regex(r"^/rest/v1/rpc/claim$"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!([
                {"agent_id": "a", "team_id": "t", "auth_email": "e", "auth_password": "p"}
            ])))
            .mount(&srv)
            .await;

        let client = SupabaseClient::new(test_cfg(srv.uri())).unwrap();
        let body: serde_json::Value = client
            .rpc_anon("claim", &serde_json::json!({"p_invite_token": "abc"}))
            .await
            .unwrap();
        assert_eq!(body[0]["agent_id"], "a");
    }

    #[tokio::test]
    async fn password_login_updates_refresh_token() {
        let srv = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path_regex(r"^/auth/v1/token$"))
            .respond_with(
                ResponseTemplate::new(200).set_body_json(serde_json::json!({
                    "access_token": "at-pwd",
                    "expires_in": 3600,
                    "refresh_token": "rt-final"
                })),
            )
            .mount(&srv)
            .await;

        let mut client = SupabaseClient::new(test_cfg(srv.uri())).unwrap();
        let tok = client
            .login_with_password("daemon+x@amux.local", "secret")
            .await
            .unwrap();
        assert_eq!(tok, "at-pwd");
        assert_eq!(client.config().refresh_token, "rt-final");
    }
}
