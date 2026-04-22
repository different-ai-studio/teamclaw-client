use crate::onboarding::invite_url;
use crate::supabase::error::SupabaseResult;
use crate::supabase::{SupabaseClient, SupabaseConfig, SUPABASE_ANON_KEY, SUPABASE_URL};
use std::path::{Path, PathBuf};

pub struct InitOutcome {
    pub actor_id: String,
    pub team_id: String,
    pub display_name: String,
    pub config_path: PathBuf,
}

/// Execute `amuxd init <amux://invite?token=...>`:
///  1. parse token
///  2. anon-RPC claim_team_invite → mint daemon auth.users + refresh_token
///  3. verify by trading refresh_token for an access_token
///  4. persist config to disk
pub async fn run(raw_url: &str, config_path: Option<&Path>) -> SupabaseResult<InitOutcome> {
    let invite = invite_url::parse(raw_url)?;

    let placeholder = SupabaseConfig {
        url: SUPABASE_URL.to_string(),
        anon_key: SUPABASE_ANON_KEY.to_string(),
        refresh_token: String::new(),
        team_id: String::new(),
        actor_id: String::new(),
    };
    let claim_client = SupabaseClient::new(placeholder)?;
    let claim = claim_client.claim_team_invite(&invite.token).await?;

    let refresh_token = claim.refresh_token.clone().ok_or_else(|| {
        crate::supabase::error::SupabaseError::Rpc {
            code: None,
            message: "claim_team_invite did not return a refresh token (kind=member?)".into(),
        }
    })?;

    let cfg = SupabaseConfig {
        url: SUPABASE_URL.to_string(),
        anon_key: SUPABASE_ANON_KEY.to_string(),
        refresh_token,
        team_id: claim.team_id.clone(),
        actor_id: claim.actor_id.clone(),
    };

    // Smoke-verify the refresh token
    let verify_client = SupabaseClient::new(cfg.clone())?;
    verify_client.access_token().await?;

    let path = match config_path {
        Some(p) => p.to_path_buf(),
        None => SupabaseConfig::default_path()?,
    };
    cfg.save(&path)?;

    Ok(InitOutcome {
        actor_id: claim.actor_id,
        team_id: claim.team_id,
        display_name: claim.display_name,
        config_path: path,
    })
}
