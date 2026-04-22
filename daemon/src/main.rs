mod agent;
mod cli;
mod collab;
mod config;
mod daemon;
mod error;
mod history;
mod mqtt;
mod onboarding;
mod proto;
mod supabase;
mod teamclaw;

use clap::Parser;
use cli::{Cli, Commands, MemberAction, TestClientAction};

fn main() -> anyhow::Result<()> {
    let cli = Cli::parse();

    match cli.command {
        Commands::Init { join_url } => {
            if let Some(url) = join_url {
                let rt = tokio::runtime::Runtime::new()?;
                let outcome = rt.block_on(onboarding::init::run(&url, None))?;
                println!(
                    "Daemon onboarded. actor_id={} team_id={} display_name={} config={}",
                    outcome.actor_id,
                    outcome.team_id,
                    outcome.display_name,
                    outcome.config_path.display()
                );
            } else {
                cli::init::run_init()?;
            }
        }
        Commands::Members { action } => match action.unwrap_or(MemberAction::List) {
            MemberAction::List => cli::members::run_list()?,
            MemberAction::Remove { member_id } => cli::members::run_remove(&member_id)?,
        },
        Commands::Start { daemonize: _, config } => {
            tracing_subscriber::fmt()
                .with_env_filter(
                    tracing_subscriber::EnvFilter::from_default_env()
                        .add_directive("amuxd=info".parse().unwrap()),
                )
                .init();

            let config_path = config.unwrap_or_else(config::DaemonConfig::default_path);
            let daemon_config = config::DaemonConfig::load(&config_path)?;

            let rt = tokio::runtime::Runtime::new()?;
            rt.block_on(async {
                let server = daemon::DaemonServer::new(daemon_config, &config_path)?;
                server.run().await
            })?;
        }
        Commands::Stop => {
            println!("Not yet implemented (requires pidfile)");
        }
        Commands::Status => {
            println!("Not yet implemented (requires running daemon)");
        }
        Commands::TestSpawn { prompt, worktree } => {
            tracing_subscriber::fmt()
                .with_env_filter(
                    tracing_subscriber::EnvFilter::from_default_env()
                        .add_directive("amuxd=debug".parse().unwrap()),
                )
                .init();

            let rt = tokio::runtime::Runtime::new()?;
            rt.block_on(async {
                let (tx, mut rx) = tokio::sync::mpsc::channel(256);
                let binary = "claude".to_string();
                println!("Spawning ACP agent: {} with prompt \"{}\" in {}", binary, prompt, worktree);

                let (initial_model_tx, _initial_model_rx) =
                    tokio::sync::oneshot::channel::<Option<String>>();
                let (acp_session_id_tx, _acp_session_id_rx) =
                    tokio::sync::oneshot::channel::<String>();
                let _cmd_tx = agent::adapter::spawn_acp_agent(
                    binary,
                    worktree.clone(),
                    prompt.clone(),
                    proto::amux::AgentType::ClaudeCode,
                    tx,
                    initial_model_tx,
                    None,
                    acp_session_id_tx,
                )?;

                println!("--- Streaming events (Ctrl+C to stop) ---\n");
                let mut count = 0u32;
                while let Some(event) = rx.recv().await {
                    count += 1;
                    match &event.event {
                        Some(proto::amux::acp_event::Event::Output(o)) => {
                            print!("{}", o.text);
                        }
                        Some(proto::amux::acp_event::Event::Thinking(t)) => {
                            println!("\n[THINKING] {}", if t.text.len() > 100 { &t.text[..100] } else { &t.text });
                        }
                        Some(proto::amux::acp_event::Event::ToolUse(tu)) => {
                            println!("\n[TOOL] {} ({})", tu.tool_name, tu.tool_id);
                        }
                        Some(proto::amux::acp_event::Event::ToolResult(tr)) => {
                            println!("[TOOL RESULT] success={} summary={}", tr.success, if tr.summary.len() > 80 { &tr.summary[..80] } else { &tr.summary });
                        }
                        Some(proto::amux::acp_event::Event::StatusChange(sc)) => {
                            println!("\n[STATUS] {:?} -> {:?}", sc.old_status, sc.new_status);
                        }
                        Some(proto::amux::acp_event::Event::Error(e)) => {
                            println!("\n[ERROR] {}", e.message);
                        }
                        _ => {
                            println!("\n[OTHER EVENT]");
                        }
                    }
                }

                println!("\n\n--- Done. {} events received ---", count);
                Ok::<(), anyhow::Error>(())
            })?;
        }
        Commands::TestClient { config, action } => {
            tracing_subscriber::fmt()
                .with_env_filter(
                    tracing_subscriber::EnvFilter::from_default_env()
                        .add_directive("amuxd=info".parse().unwrap()),
                )
                .init();

            let config_path = config.unwrap_or_else(config::DaemonConfig::default_path);
            let daemon_config = config::DaemonConfig::load(&config_path)?;

            let rt = tokio::runtime::Runtime::new()?;
            rt.block_on(async {
                match action {
                    TestClientAction::Watch => cli::test_client::run_watch(daemon_config).await?,
                    TestClientAction::StartAgent { worktree, prompt } => {
                        cli::test_client::run_start_agent(daemon_config, &worktree, &prompt).await?;
                    }
                    TestClientAction::Announce { token } => {
                        cli::test_client::run_announce(daemon_config, &token).await?;
                    }
                    TestClientAction::E2e { token, worktree, prompt } => {
                        cli::test_client::run_e2e(daemon_config, &token, &worktree, &prompt).await?;
                    }
                }
                Ok::<(), anyhow::Error>(())
            })?;
        }
    }

    Ok(())
}
