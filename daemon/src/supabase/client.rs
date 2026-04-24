use crate::supabase::config::SupabaseConfig;
use crate::supabase::error::{SupabaseError, SupabaseResult};
use reqwest::Client;
use serde::{Deserialize, Serialize};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tokio::sync::Mutex as AsyncMutex;

// chrono re-exported for callers constructing AgentRuntimeUpsert
pub use chrono;

#[derive(Debug, Clone)]
pub struct SupabaseClient {
    http: Client,
    cfg: SupabaseConfig,
    persist_path: Option<std::path::PathBuf>,
    state: Arc<Mutex<AuthState>>,
    /// Serializes `refresh()` so two concurrent callers can't race to spend
    /// the same refresh token (GoTrue invalidates the presented token and
    /// hands back a new one — a second concurrent call sees the old token
    /// return 400 refresh_token_already_used).
    refresh_lock: Arc<AsyncMutex<()>>,
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
        let persist_path = SupabaseConfig::default_path().ok();
        Self::new_with_persistence(cfg, persist_path)
    }

    pub fn new_without_persistence(cfg: SupabaseConfig) -> SupabaseResult<Self> {
        Self::new_with_persistence(cfg, None)
    }

    fn new_with_persistence(
        cfg: SupabaseConfig,
        persist_path: Option<std::path::PathBuf>,
    ) -> SupabaseResult<Self> {
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
            persist_path,
            state: Arc::new(Mutex::new(state)),
            refresh_lock: Arc::new(AsyncMutex::new(())),
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
        let _guard = self.refresh_lock.lock().await;

        // Another caller may have just refreshed while we were queued on
        // the mutex. Re-check the cache before spending the stored token.
        {
            let st = self.state.lock().unwrap();
            if let (Some(tok), Some(exp)) = (&st.access_token, st.expires_at) {
                if exp > Instant::now() + REFRESH_SKEW {
                    return Ok(tok.clone());
                }
            }
        }

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

        // Persist the rotated refresh token so the next daemon start doesn't
        // boot with a stale one GoTrue has already invalidated.
        let new_refresh = body.refresh_token.clone();
        {
            let mut st = self.state.lock().unwrap();
            st.access_token = Some(body.access_token.clone());
            st.refresh_token = new_refresh.clone();
            st.expires_at = Some(Instant::now() + Duration::from_secs(body.expires_in));
        }
        if let Some(path) = &self.persist_path {
            let mut persisted = self.cfg.clone();
            persisted.refresh_token = new_refresh;
            let _ = persisted.save(path);
        }
        Ok(body.access_token)
    }

    /// Expiry of the currently cached access token without triggering a refresh.
    /// Returns `None` if no token has been fetched yet.
    pub fn cached_token_expiry(&self) -> Option<Instant> {
        #[cfg(debug_assertions)]
        if let Ok(secs_str) = std::env::var("AMUX_FORCE_TOKEN_EXPIRY_SECS") {
            if let Ok(n) = secs_str.parse::<u64>() {
                return Some(Instant::now() + Duration::from_secs(n));
            }
        }
        self.state.lock().unwrap().expires_at
    }

    /// Returns true if the cached token is at or past its expiry.
    pub fn is_token_expired(&self) -> bool {
        self.state.lock().unwrap()
            .expires_at
            .map(|t| Instant::now() >= t)
            .unwrap_or(false)
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

    /// Anonymous claim for agents (daemon path). Calls `claim_team_invite` RPC.
    /// Supabase's PostgREST always returns a set-returning function as an array,
    /// so we deserialize into `Vec<ClaimResult>` and pick the first row.
    pub async fn claim_team_invite(&self, token: &str) -> SupabaseResult<ClaimResult> {
        #[derive(Serialize)]
        struct Req<'a> {
            p_token: &'a str,
        }
        let payload = Req { p_token: token };
        let rows: Vec<ClaimResult> = self.rpc_anon("claim_team_invite", &payload).await?;
        rows.into_iter().next().ok_or(SupabaseError::InviteInvalid)
    }
}

/// Returned by `public.claim_team_invite` — both member and agent branches.
/// `refresh_token` is `None` for member claims.
#[derive(Debug, Deserialize)]
pub struct ClaimResult {
    pub actor_id: String,
    pub team_id: String,
    pub actor_type: String,
    pub display_name: String,
    pub refresh_token: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct AgentRuntimeUpsert<'a> {
    pub team_id: &'a str,
    pub agent_id: &'a str,
    pub session_id: Option<&'a str>,
    pub workspace_id: Option<&'a str>,
    pub backend_type: &'a str,
    pub backend_session_id: Option<&'a str>,
    pub status: &'a str,
    pub current_model: Option<&'a str>,
    pub last_seen_at: chrono::DateTime<chrono::Utc>,
}

#[derive(Debug, Serialize)]
pub struct WorkspaceUpsert<'a> {
    pub team_id: &'a str,
    pub agent_id: &'a str,
    pub name: &'a str,
    pub path: Option<&'a str>,
    pub archived: bool,
}

#[derive(Debug, Deserialize)]
pub struct WorkspaceRow {
    pub id: String,
}

impl SupabaseClient {
    /// Upsert an agent_runtimes row keyed on (agent_id, backend_session_id).
    pub async fn upsert_agent_runtime(
        &self,
        row: &AgentRuntimeUpsert<'_>,
    ) -> SupabaseResult<()> {
        let token = self.access_token().await?;
        let url = format!(
            "{}/rest/v1/agent_runtimes?on_conflict=agent_id,backend_session_id",
            self.cfg.url
        );
        let resp = self
            .http
            .post(&url)
            .header("apikey", &self.cfg.anon_key)
            .header("Prefer", "resolution=merge-duplicates")
            .bearer_auth(token)
            .json(&[row])
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
        Ok(())
    }

    /// Record this daemon's MQTT device identifier on its `agents` row so
    /// iOS clients can route publishes to `amux/{device_id}/…` without having
    /// the user hand-type the UUID.
    pub async fn set_agent_device_id(&self, device_id: &str) -> SupabaseResult<()> {
        let token = self.access_token().await?;
        let actor_id = self.cfg.actor_id.clone();
        let url = format!(
            "{}/rest/v1/agents?id=eq.{}",
            self.cfg.url, actor_id
        );
        #[derive(Serialize)]
        struct Patch<'a> { device_id: &'a str }
        let resp = self
            .http
            .patch(&url)
            .header("apikey", &self.cfg.anon_key)
            .bearer_auth(token)
            .json(&Patch { device_id })
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
        Ok(())
    }

    /// Look up `agent_member_access.permission_level` for a caller. Returns
    /// `Some("admin" | "write" | "view")` or `None` when no grant exists.
    pub async fn check_agent_permission(
        &self,
        agent_id: &str,
        actor_id: &str,
    ) -> SupabaseResult<Option<String>> {
        #[derive(Serialize)]
        struct Req<'a> { p_agent_id: &'a str, p_actor_id: &'a str }
        let body: serde_json::Value =
            self.rpc("check_agent_permission", &Req {
                p_agent_id: agent_id,
                p_actor_id: actor_id,
            }).await?;
        Ok(body.as_str().map(str::to_string))
    }

    /// Heartbeat: POST /rest/v1/rpc/update_actor_last_active.
    /// The RPC returns void (empty body), so we can't decode the response as JSON.
    pub async fn heartbeat(&self) -> SupabaseResult<()> {
        let token = self.access_token().await?;
        let url = format!("{}/rest/v1/rpc/update_actor_last_active", self.cfg.url);
        let resp = self
            .http
            .post(&url)
            .header("apikey", &self.cfg.anon_key)
            .bearer_auth(token)
            .json(&serde_json::Value::Null)
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
        Ok(())
    }

    pub async fn upsert_workspace(
        &self,
        row: &WorkspaceUpsert<'_>,
    ) -> SupabaseResult<WorkspaceRow> {
        let token = self.access_token().await?;
        let url = format!(
            "{}/rest/v1/workspaces?on_conflict=team_id,agent_id,name",
            self.cfg.url
        );
        let resp = self
            .http
            .post(&url)
            .header("apikey", &self.cfg.anon_key)
            .header("Prefer", "resolution=merge-duplicates,return=representation")
            .bearer_auth(token)
            .json(&[row])
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

        let mut rows: Vec<WorkspaceRow> = resp.json().await?;
        rows.pop().ok_or(SupabaseError::Rpc {
            code: None,
            message: "workspace upsert returned no rows".into(),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
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

        let client = SupabaseClient::new_without_persistence(test_cfg(srv.uri())).unwrap();
        let tok = client.access_token().await.unwrap();
        assert_eq!(tok, "at-new");

        let tok2 = client.access_token().await.unwrap();
        assert_eq!(tok2, "at-new");
    }

    #[tokio::test]
    async fn test_clients_do_not_persist_runtime_config() {
        let path = SupabaseConfig::default_path().unwrap();
        let original = fs::read(&path).ok();

        let srv = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path_regex(r"^/auth/v1/token$"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "access_token": "at-new",
                "expires_in": 3600,
                "refresh_token": "rt-1"
            })))
            .mount(&srv)
            .await;

        let client = SupabaseClient::new_without_persistence(test_cfg(srv.uri())).unwrap();
        let _ = client.access_token().await.unwrap();

        let persisted = fs::read(&path).ok();
        assert_eq!(persisted, original);
    }

    #[tokio::test]
    async fn refresh_failure_is_auth_error() {
        let srv = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path_regex(r"^/auth/v1/token$"))
            .respond_with(ResponseTemplate::new(400).set_body_string("bad"))
            .mount(&srv)
            .await;

        let client = SupabaseClient::new_without_persistence(test_cfg(srv.uri())).unwrap();
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

        let client = SupabaseClient::new_without_persistence(test_cfg(srv.uri())).unwrap();
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
                {"actor_id": "a", "team_id": "t", "actor_type": "agent",
                 "display_name": "Test", "refresh_token": null}
            ])))
            .mount(&srv)
            .await;

        let client = SupabaseClient::new_without_persistence(test_cfg(srv.uri())).unwrap();
        let body: serde_json::Value = client
            .rpc_anon("claim", &serde_json::json!({"p_token": "abc"}))
            .await
            .unwrap();
        assert_eq!(body[0]["actor_id"], "a");
    }

    #[tokio::test]
    async fn claim_team_invite_decodes_agent_response() {
        let srv = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path_regex(r"^/rest/v1/rpc/claim_team_invite$"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!([{
                "actor_id": "a", "team_id": "t", "actor_type": "agent",
                "display_name": "M1 Studio", "refresh_token": "rt"
            }])))
            .mount(&srv)
            .await;

        let client = SupabaseClient::new(test_cfg(srv.uri())).unwrap();
        let r = client.claim_team_invite("opaque-token-abc123").await.unwrap();
        assert_eq!(r.actor_type, "agent");
        assert_eq!(r.refresh_token.as_deref(), Some("rt"));
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

        let mut client = SupabaseClient::new_without_persistence(test_cfg(srv.uri())).unwrap();
        let tok = client
            .login_with_password("daemon+x@amux.local", "secret")
            .await
            .unwrap();
        assert_eq!(tok, "at-pwd");
        assert_eq!(client.config().refresh_token, "rt-final");
    }

    #[tokio::test]
    async fn upsert_agent_runtime_sends_merge_duplicates_header() {
        let srv = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path_regex(r"^/rest/v1/agent_runtimes"))
            .and(wiremock::matchers::header("Prefer", "resolution=merge-duplicates"))
            .respond_with(ResponseTemplate::new(201))
            .mount(&srv)
            .await;
        Mock::given(method("POST"))
            .and(path_regex(r"^/auth/v1/token$"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "access_token": "at", "expires_in": 3600, "refresh_token": "rt"
            })))
            .mount(&srv)
            .await;

        let client = SupabaseClient::new_without_persistence(test_cfg(srv.uri())).unwrap();
        let row = AgentRuntimeUpsert {
            team_id: "t",
            agent_id: "a",
            session_id: None,
            workspace_id: None,
            backend_type: "claude",
            backend_session_id: Some("s-1"),
            status: "running",
            current_model: Some("opus"),
            last_seen_at: chrono::Utc::now(),
        };
        client.upsert_agent_runtime(&row).await.unwrap();
    }

    #[tokio::test]
    async fn upsert_workspace_returns_supabase_uuid() {
        let srv = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path_regex(r"^/rest/v1/.*$"))
            .respond_with(ResponseTemplate::new(201).set_body_json(serde_json::json!([
                { "id": "11111111-1111-1111-1111-111111111111" }
            ])))
            .mount(&srv)
            .await;
        Mock::given(method("POST"))
            .and(path_regex(r"^/auth/v1/token$"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "access_token": "at", "expires_in": 3600, "refresh_token": "rt"
            })))
            .mount(&srv)
            .await;

        let client = SupabaseClient::new_without_persistence(test_cfg(srv.uri())).unwrap();
        let row = WorkspaceUpsert {
            team_id: "team-1",
            agent_id: "agent-1",
            name: "amux",
            path: Some("/tmp/amux"),
            archived: false,
        };

        let workspace = client.upsert_workspace(&row).await.unwrap();
        assert_eq!(workspace.id, "11111111-1111-1111-1111-111111111111");
    }

    #[test]
    fn cached_token_expiry_is_none_before_any_fetch() {
        let cfg = SupabaseConfig {
            url: "http://localhost".into(),
            anon_key: "key".into(),
            refresh_token: "tok".into(),
            team_id: "team".into(),
            actor_id: "actor".into(),
        };
        let client = SupabaseClient::new_without_persistence(cfg).unwrap();
        assert!(client.cached_token_expiry().is_none());
    }

    #[test]
    fn is_token_expired_false_when_expiry_in_future() {
        let cfg = SupabaseConfig {
            url: "http://localhost".into(),
            anon_key: "key".into(),
            refresh_token: "tok".into(),
            team_id: "team".into(),
            actor_id: "actor".into(),
        };
        let client = SupabaseClient::new_without_persistence(cfg).unwrap();
        {
            let mut st = client.state.lock().unwrap();
            st.expires_at = Some(Instant::now() + Duration::from_secs(3600));
        }
        assert!(!client.is_token_expired());
    }

    #[test]
    fn is_token_expired_true_when_expiry_in_past() {
        let cfg = SupabaseConfig {
            url: "http://localhost".into(),
            anon_key: "key".into(),
            refresh_token: "tok".into(),
            team_id: "team".into(),
            actor_id: "actor".into(),
        };
        let client = SupabaseClient::new_without_persistence(cfg).unwrap();
        {
            let mut st = client.state.lock().unwrap();
            st.expires_at = Some(Instant::now() - Duration::from_secs(1));
        }
        assert!(client.is_token_expired());
    }
}
