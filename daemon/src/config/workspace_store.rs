use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

use crate::proto::amux;

#[derive(Debug, Serialize, Deserialize)]
pub struct WorkspaceStore {
    #[serde(default)]
    pub workspaces: Vec<StoredWorkspace>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StoredWorkspace {
    pub workspace_id: String,
    pub path: String,
    pub display_name: String,
}

impl WorkspaceStore {
    pub fn default_path() -> PathBuf {
        super::DaemonConfig::config_dir().join("workspaces.toml")
    }

    pub fn load(path: &Path) -> crate::error::Result<Self> {
        if !path.exists() {
            return Ok(Self { workspaces: vec![] });
        }
        let content = std::fs::read_to_string(path)
            .map_err(|e| crate::error::AmuxError::Config(format!("read {}: {}", path.display(), e)))?;
        toml::from_str(&content)
            .map_err(|e| crate::error::AmuxError::Config(format!("parse {}: {}", path.display(), e)))
    }

    pub fn save(&self, path: &Path) -> crate::error::Result<()> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let content = toml::to_string_pretty(self)
            .map_err(|e| crate::error::AmuxError::Config(e.to_string()))?;
        std::fs::write(path, content)?;
        Ok(())
    }

    pub fn add(&mut self, dir_path: &str) -> crate::error::Result<StoredWorkspace> {
        let p = Path::new(dir_path);
        if !p.is_dir() {
            return Err(crate::error::AmuxError::Config(format!(
                "path is not a directory: {}",
                dir_path
            )));
        }

        // Deduplicate by canonical path
        let canonical = p
            .canonicalize()
            .map_err(|e| crate::error::AmuxError::Config(format!("canonicalize {}: {}", dir_path, e)))?;
        let canonical_str = canonical.to_string_lossy().to_string();

        if let Some(existing) = self.workspaces.iter().find(|w| w.path == canonical_str) {
            return Ok(existing.clone());
        }

        let display_name = canonical
            .file_name()
            .map(|n| n.to_string_lossy().to_string())
            .unwrap_or_else(|| canonical_str.clone());

        let workspace_id = uuid::Uuid::new_v4()
            .to_string()
            .chars()
            .take(8)
            .collect::<String>();

        let workspace = StoredWorkspace {
            workspace_id,
            path: canonical_str,
            display_name,
        };
        self.workspaces.push(workspace.clone());
        Ok(workspace)
    }

    pub fn remove(&mut self, workspace_id: &str) -> bool {
        let len = self.workspaces.len();
        self.workspaces.retain(|w| w.workspace_id != workspace_id);
        self.workspaces.len() < len
    }

    pub fn find_by_id(&self, workspace_id: &str) -> Option<&StoredWorkspace> {
        self.workspaces.iter().find(|w| w.workspace_id == workspace_id)
    }

    pub fn to_proto_list(&self) -> amux::WorkspaceList {
        amux::WorkspaceList {
            workspaces: self
                .workspaces
                .iter()
                .map(|w| amux::WorkspaceInfo {
                    workspace_id: w.workspace_id.clone(),
                    path: w.path.clone(),
                    display_name: w.display_name.clone(),
                })
                .collect(),
        }
    }
}
