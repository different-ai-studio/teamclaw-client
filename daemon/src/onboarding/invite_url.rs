use crate::supabase::error::{SupabaseError, SupabaseResult};
use url::Url;

/// Parsed representation of an `amux://invite?token=<opaque>` deeplink.
/// Token is an opaque URL-safe string produced by `create_team_invite`
/// (currently ~32 chars of base64url).
pub struct ParsedInvite {
    pub token: String,
}

/// Accepts `amux://invite?token=<opaque>`. Previously also accepted url/anon
/// query params — those are now compile-time constants in the daemon binary.
pub fn parse(raw: &str) -> SupabaseResult<ParsedInvite> {
    let url = Url::parse(raw)
        .map_err(|e| SupabaseError::Config(format!("parse invite url: {e}")))?;

    if url.scheme() != "amux" {
        return Err(SupabaseError::Config(format!(
            "invite url scheme must be 'amux', got {}",
            url.scheme()
        )));
    }
    if url.host_str() != Some("invite") {
        return Err(SupabaseError::Config(format!(
            "invite url host must be 'invite', got {:?}",
            url.host_str()
        )));
    }

    let token = url
        .query_pairs()
        .find(|(k, _)| k == "token")
        .map(|(_, v)| v.into_owned())
        .ok_or_else(|| SupabaseError::Config("invite url missing 'token'".into()))?;
    if token.is_empty() {
        return Err(SupabaseError::Config("invite token is empty".into()));
    }

    Ok(ParsedInvite { token })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_valid_invite_url() {
        let p = parse("amux://invite?token=ABCDEF-12345_xyz").unwrap();
        assert_eq!(p.token, "ABCDEF-12345_xyz");
    }

    #[test]
    fn rejects_wrong_scheme() {
        assert!(parse("http://invite?token=x").is_err());
    }

    #[test]
    fn rejects_wrong_host() {
        assert!(parse("amux://join?token=x").is_err());
    }

    #[test]
    fn rejects_missing_token() {
        assert!(parse("amux://invite").is_err());
    }

    #[test]
    fn rejects_empty_token() {
        assert!(parse("amux://invite?token=").is_err());
    }
}
