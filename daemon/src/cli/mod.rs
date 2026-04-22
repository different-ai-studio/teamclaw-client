pub mod init;
pub mod members;
pub mod test_client;

use clap::{Parser, Subcommand};
use std::path::PathBuf;

#[derive(Parser)]
#[command(name = "amuxd", version, about = "AMUX Agent Multiplexer Daemon")]
pub struct Cli {
    #[command(subcommand)]
    pub command: Commands,
}

#[derive(Subcommand)]
pub enum Commands {
    /// Start the daemon
    Start {
        #[arg(short, long)]
        daemonize: bool,
        #[arg(long)]
        config: Option<PathBuf>,
    },
    /// Stop the running daemon
    Stop,
    /// Show daemon status
    Status,
    /// First-time setup wizard. With a join URL, onboards the daemon
    /// to Supabase via the invite token issued by iOS.
    Init {
        /// amux://join?token=...&url=...&anon=... URL from an iOS invite.
        join_url: Option<String>,
    },
    /// Manage members
    Members {
        #[command(subcommand)]
        action: Option<MemberAction>,
    },
    /// Test: spawn claude and print parsed events (for development)
    TestSpawn {
        /// Prompt to send
        prompt: String,
        /// Working directory
        #[arg(long, default_value = ".")]
        worktree: String,
    },
    /// Test: simulate an iOS client — connect to broker, send commands, watch events
    TestClient {
        /// Config file path (uses same daemon.toml)
        #[arg(long)]
        config: Option<std::path::PathBuf>,
        #[command(subcommand)]
        action: TestClientAction,
    },
}

#[derive(Subcommand)]
pub enum TestClientAction {
    /// Watch all events from the daemon (subscribe to all topics)
    Watch,
    /// Send a StartAgent command
    StartAgent {
        worktree: String,
        prompt: String,
    },
    /// Send a PeerAnnounce (authenticate with token)
    Announce {
        token: String,
    },
    /// Full E2E: announce → start agent → watch events (single connection)
    E2e {
        token: String,
        worktree: String,
        prompt: String,
    },
}

#[derive(Subcommand)]
pub enum MemberAction {
    List,
    Remove { member_id: String },
}
