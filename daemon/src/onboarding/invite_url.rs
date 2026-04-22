use crate::supabase::error::{SupabaseError, SupabaseResult};
use uuid::Uuid;

#[derive(Debug, PartialEq, Eq)]
pub struct JoinUrl {
    pub token: Uuid,
    pub url: String,
    pub anon_key: String,
}

pub fn parse(raw: &str) -> SupabaseResult<JoinUrl> {
    let rest = raw
        .strip_prefix("amux://join?")
        .ok_or_else(|| SupabaseError::Config("not an amux://join URL".into()))?;

    let mut token: Option<Uuid> = None;
    let mut url: Option<String> = None;
    let mut anon: Option<String> = None;
    for pair in rest.split('&') {
        let (k, v) = pair
            .split_once('=')
            .ok_or_else(|| SupabaseError::Config(format!("bad pair: {pair}")))?;
        let v = percent_decode(v);
        match k {
            "token" => {
                token = Some(
                    Uuid::parse_str(&v)
                        .map_err(|e| SupabaseError::Config(format!("uuid: {e}")))?,
                );
            }
            "url" => url = Some(v),
            "anon" => anon = Some(v),
            _ => {}
        }
    }
    Ok(JoinUrl {
        token: token.ok_or_else(|| SupabaseError::Config("missing token".into()))?,
        url: url.ok_or_else(|| SupabaseError::Config("missing url".into()))?,
        anon_key: anon.ok_or_else(|| SupabaseError::Config("missing anon".into()))?,
    })
}

fn percent_decode(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let bytes = s.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            if let Ok(n) = u8::from_str_radix(
                std::str::from_utf8(&bytes[i + 1..i + 3]).unwrap_or("00"),
                16,
            ) {
                out.push(n as char);
                i += 3;
                continue;
            }
        }
        out.push(bytes[i] as char);
        i += 1;
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_full_url() {
        let raw = "amux://join?token=9f6b6e53-8d4e-4f7a-9f58-d9d1c7b2e8a5\
                   &url=https%3A%2F%2Fx.supabase.co&anon=anon123";
        let got = parse(raw).unwrap();
        assert_eq!(
            got.token,
            Uuid::parse_str("9f6b6e53-8d4e-4f7a-9f58-d9d1c7b2e8a5").unwrap()
        );
        assert_eq!(got.url, "https://x.supabase.co");
        assert_eq!(got.anon_key, "anon123");
    }

    #[test]
    fn rejects_wrong_scheme() {
        assert!(parse("https://x?token=x").is_err());
    }

    #[test]
    fn rejects_missing_token() {
        assert!(parse("amux://join?url=x&anon=y").is_err());
    }

    #[test]
    fn rejects_malformed_uuid() {
        assert!(parse("amux://join?token=not-a-uuid&url=u&anon=a").is_err());
    }
}
