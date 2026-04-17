use chrono::{Duration, Utc};
use uuid::Uuid;

use crate::config::{MemberStore, PendingInvite, StoredMember};
use crate::proto::amux;

pub struct AuthManager {
    store_path: std::path::PathBuf,
    store: MemberStore,
}

pub enum AuthResult {
    Accepted { member: StoredMember },
    Rejected { reason: String },
}

impl AuthManager {
    pub fn new(store_path: std::path::PathBuf) -> crate::error::Result<Self> {
        let store = MemberStore::load(&store_path)?;
        Ok(Self { store_path, store })
    }

    pub fn authenticate(&mut self, token: &str) -> AuthResult {
        if let Some(member) = self.store.find_member_by_token(token) {
            return AuthResult::Accepted { member: member.clone() };
        }

        if self.store.find_pending_invite(token).is_some() {
            let invite = self.store.consume_invite(token).unwrap();
            let member = StoredMember {
                member_id: Uuid::new_v4().to_string(),
                display_name: invite.display_name.clone(),
                role: invite.role.clone(),
                token: invite.invite_token.clone(), // Keep invite token so iOS can re-auth
                joined_at: Utc::now(),
            };
            self.store.add_member(member.clone());
            let _ = self.store.save(&self.store_path);
            return AuthResult::Accepted { member };
        }

        AuthResult::Rejected {
            reason: "invalid or expired token".into(),
        }
    }

    pub fn create_invite(&mut self, display_name: &str, expires_hours: u32, role: &str) -> crate::error::Result<PendingInvite> {
        let invite = PendingInvite {
            invite_token: Uuid::new_v4().to_string(),
            display_name: display_name.into(),
            created_at: Utc::now(),
            expires_at: Utc::now() + Duration::hours(expires_hours as i64),
            role: role.into(),
        };
        self.store.add_invite(invite.clone());
        self.store.save(&self.store_path)?;
        Ok(invite)
    }

    pub fn remove_member(&mut self, member_id: &str) -> crate::error::Result<bool> {
        let removed = self.store.remove_member(member_id);
        if removed {
            self.store.save(&self.store_path)?;
        }
        Ok(removed)
    }

    pub fn to_proto_member_list(&self) -> amux::MemberList {
        amux::MemberList {
            members: self.store.members.iter().map(|m| amux::MemberInfo {
                member_id: m.member_id.clone(),
                display_name: m.display_name.clone(),
                role: if m.is_owner() { amux::MemberRole::Owner as i32 } else { amux::MemberRole::Member as i32 },
                joined_at: m.joined_at.timestamp(),
                department: String::new(),
            }).collect(),
        }
    }

    pub fn is_owner(&self, member_id: &str) -> bool {
        self.store.members.iter().any(|m| m.member_id == member_id && m.is_owner())
    }

    /// Look up a member's role by matching the start of their token.
    /// Used when peer state was lost (daemon restart) but we can recover from peer_id format.
    pub fn find_role_by_token_prefix(&self, prefix: &str) -> Option<amux::MemberRole> {
        self.store.members.iter()
            .find(|m| m.token.starts_with(prefix))
            .map(|m| if m.is_owner() { amux::MemberRole::Owner } else { amux::MemberRole::Member })
    }
}
