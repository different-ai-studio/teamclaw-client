use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use std::path::Path;

use crate::proto::teamclaw;

#[derive(Debug, Default, Serialize, Deserialize)]
pub struct WorkItemStore {
    #[serde(default)]
    pub items: Vec<StoredWorkItem>,
    #[serde(default)]
    pub claims: Vec<StoredClaim>,
    #[serde(default)]
    pub submissions: Vec<StoredSubmission>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StoredWorkItem {
    pub work_item_id: String,
    pub session_id: String,
    pub title: String,
    pub description: String,
    pub status: String,
    #[serde(default)]
    pub parent_id: String,
    pub created_by: String,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StoredClaim {
    pub claim_id: String,
    pub work_item_id: String,
    pub actor_id: String,
    pub claimed_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StoredSubmission {
    pub submission_id: String,
    pub work_item_id: String,
    pub actor_id: String,
    pub content: String,
    pub submitted_at: DateTime<Utc>,
}

impl WorkItemStore {
    fn path_for(base_dir: &Path, session_id: &str) -> std::path::PathBuf {
        base_dir
            .join("teamclaw")
            .join("sessions")
            .join(session_id)
            .join("workitems.toml")
    }

    pub fn load(base_dir: &Path, session_id: &str) -> crate::error::Result<Self> {
        let path = Self::path_for(base_dir, session_id);
        if !path.exists() {
            return Ok(Self::default());
        }
        let content = std::fs::read_to_string(&path)
            .map_err(|e| crate::error::AmuxError::Config(format!("read {}: {}", path.display(), e)))?;
        toml::from_str(&content)
            .map_err(|e| crate::error::AmuxError::Config(format!("parse {}: {}", path.display(), e)))
    }

    pub fn save(&self, base_dir: &Path, session_id: &str) -> crate::error::Result<()> {
        let path = Self::path_for(base_dir, session_id);
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let content = toml::to_string_pretty(self)
            .map_err(|e| crate::error::AmuxError::Config(e.to_string()))?;
        std::fs::write(&path, content)?;
        Ok(())
    }

    pub fn add_item(&mut self, item: StoredWorkItem) {
        self.items.push(item);
    }

    pub fn find_item(&self, work_item_id: &str) -> Option<&StoredWorkItem> {
        self.items.iter().find(|i| i.work_item_id == work_item_id)
    }

    pub fn find_item_mut(&mut self, work_item_id: &str) -> Option<&mut StoredWorkItem> {
        self.items.iter_mut().find(|i| i.work_item_id == work_item_id)
    }

    /// Adds a claim and automatically updates the work item status to "in_progress".
    pub fn add_claim(&mut self, claim: StoredClaim) {
        if let Some(item) = self.find_item_mut(&claim.work_item_id) {
            item.status = "in_progress".to_string();
        }
        self.claims.push(claim);
    }

    pub fn add_submission(&mut self, submission: StoredSubmission) {
        self.submissions.push(submission);
    }

    pub fn claims_for_item(&self, work_item_id: &str) -> Vec<&StoredClaim> {
        self.claims.iter().filter(|c| c.work_item_id == work_item_id).collect()
    }

    pub fn submissions_for_item(&self, work_item_id: &str) -> Vec<&StoredSubmission> {
        self.submissions.iter().filter(|s| s.work_item_id == work_item_id).collect()
    }

    pub fn items_claimed_by(&self, actor_id: &str) -> Vec<&StoredWorkItem> {
        let claimed_ids: std::collections::HashSet<&str> = self.claims
            .iter()
            .filter(|c| c.actor_id == actor_id)
            .map(|c| c.work_item_id.as_str())
            .collect();
        self.items.iter().filter(|i| claimed_ids.contains(i.work_item_id.as_str())).collect()
    }

    pub fn to_proto_work_item(&self, item: &StoredWorkItem) -> teamclaw::WorkItem {
        let claims = self.claims_for_item(&item.work_item_id)
            .into_iter()
            .map(|c| teamclaw::Claim {
                claim_id: c.claim_id.clone(),
                work_item_id: c.work_item_id.clone(),
                actor_id: c.actor_id.clone(),
                claimed_at: c.claimed_at.timestamp(),
            })
            .collect();

        let submissions = self.submissions_for_item(&item.work_item_id)
            .into_iter()
            .map(|s| teamclaw::Submission {
                submission_id: s.submission_id.clone(),
                work_item_id: s.work_item_id.clone(),
                actor_id: s.actor_id.clone(),
                content: s.content.clone(),
                submitted_at: s.submitted_at.timestamp(),
            })
            .collect();

        teamclaw::WorkItem {
            work_item_id: item.work_item_id.clone(),
            session_id: item.session_id.clone(),
            title: item.title.clone(),
            description: item.description.clone(),
            status: work_item_status_to_proto(&item.status) as i32,
            parent_id: item.parent_id.clone(),
            created_by: item.created_by.clone(),
            created_at: item.created_at.timestamp(),
            claims,
            submissions,
        }
    }
}

fn work_item_status_to_proto(s: &str) -> teamclaw::WorkItemStatus {
    match s {
        "open" => teamclaw::WorkItemStatus::Open,
        "in_progress" => teamclaw::WorkItemStatus::InProgress,
        "done" => teamclaw::WorkItemStatus::Done,
        _ => teamclaw::WorkItemStatus::Unknown,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::Utc;
    use tempfile::TempDir;

    fn make_work_item(id: &str, session_id: &str) -> StoredWorkItem {
        StoredWorkItem {
            work_item_id: id.to_string(),
            session_id: session_id.to_string(),
            title: format!("Item {}", id),
            description: "desc".to_string(),
            status: "open".to_string(),
            parent_id: String::new(),
            created_by: "user1".to_string(),
            created_at: Utc::now(),
        }
    }

    fn make_claim(id: &str, work_item_id: &str, actor_id: &str) -> StoredClaim {
        StoredClaim {
            claim_id: id.to_string(),
            work_item_id: work_item_id.to_string(),
            actor_id: actor_id.to_string(),
            claimed_at: Utc::now(),
        }
    }

    fn make_submission(id: &str, work_item_id: &str, actor_id: &str) -> StoredSubmission {
        StoredSubmission {
            submission_id: id.to_string(),
            work_item_id: work_item_id.to_string(),
            actor_id: actor_id.to_string(),
            content: "result".to_string(),
            submitted_at: Utc::now(),
        }
    }

    #[test]
    fn test_add_and_find_item() {
        let mut store = WorkItemStore::default();
        store.add_item(make_work_item("w1", "s1"));
        assert!(store.find_item("w1").is_some());
        assert!(store.find_item("w2").is_none());
    }

    #[test]
    fn test_add_claim_updates_status() {
        let mut store = WorkItemStore::default();
        store.add_item(make_work_item("w1", "s1"));
        assert_eq!(store.find_item("w1").unwrap().status, "open");

        store.add_claim(make_claim("c1", "w1", "agent1"));
        assert_eq!(store.find_item("w1").unwrap().status, "in_progress");
        assert_eq!(store.claims.len(), 1);
    }

    #[test]
    fn test_add_claim_no_matching_item() {
        let mut store = WorkItemStore::default();
        // Claim for nonexistent item should still be stored
        store.add_claim(make_claim("c1", "w999", "agent1"));
        assert_eq!(store.claims.len(), 1);
    }

    #[test]
    fn test_claims_for_item() {
        let mut store = WorkItemStore::default();
        store.add_item(make_work_item("w1", "s1"));
        store.add_claim(make_claim("c1", "w1", "agent1"));
        store.add_claim(make_claim("c2", "w1", "agent2"));
        store.add_claim(make_claim("c3", "w2", "agent1")); // different item

        let claims = store.claims_for_item("w1");
        assert_eq!(claims.len(), 2);
    }

    #[test]
    fn test_submissions_for_item() {
        let mut store = WorkItemStore::default();
        store.add_submission(make_submission("s1", "w1", "agent1"));
        store.add_submission(make_submission("s2", "w1", "agent2"));
        store.add_submission(make_submission("s3", "w2", "agent1"));

        let subs = store.submissions_for_item("w1");
        assert_eq!(subs.len(), 2);
    }

    #[test]
    fn test_items_claimed_by() {
        let mut store = WorkItemStore::default();
        store.add_item(make_work_item("w1", "s1"));
        store.add_item(make_work_item("w2", "s1"));
        store.add_item(make_work_item("w3", "s1"));
        store.add_claim(make_claim("c1", "w1", "agent1"));
        store.add_claim(make_claim("c2", "w3", "agent1"));
        store.add_claim(make_claim("c3", "w2", "agent2"));

        let items = store.items_claimed_by("agent1");
        assert_eq!(items.len(), 2);
    }

    #[test]
    fn test_save_and_load() {
        let tmp = TempDir::new().unwrap();
        let mut store = WorkItemStore::default();
        store.add_item(make_work_item("w1", "s1"));
        store.add_claim(make_claim("c1", "w1", "agent1"));
        store.add_submission(make_submission("sub1", "w1", "agent1"));
        store.save(tmp.path(), "s1").unwrap();

        let loaded = WorkItemStore::load(tmp.path(), "s1").unwrap();
        assert_eq!(loaded.items.len(), 1);
        assert_eq!(loaded.claims.len(), 1);
        assert_eq!(loaded.submissions.len(), 1);
        // Verify claim updated status was persisted
        assert_eq!(loaded.items[0].status, "in_progress");
    }

    #[test]
    fn test_to_proto_work_item() {
        let mut store = WorkItemStore::default();
        store.add_item(make_work_item("w1", "s1"));
        store.add_claim(make_claim("c1", "w1", "agent1"));
        store.add_submission(make_submission("sub1", "w1", "agent1"));

        let proto = store.to_proto_work_item(store.find_item("w1").unwrap());
        assert_eq!(proto.work_item_id, "w1");
        assert_eq!(proto.status, teamclaw::WorkItemStatus::InProgress as i32);
        assert_eq!(proto.claims.len(), 1);
        assert_eq!(proto.submissions.len(), 1);
    }
}
