use rumqttc::{Event, Packet};
use tracing::{error, info, warn};

use crate::config::{DaemonConfig, MemberStore, SessionStore, StoredSession, WorkspaceStore};
use crate::mqtt::{MqttClient, publisher::Publisher, subscriber};
use std::path::PathBuf;
use crate::agent::AgentManager;
use crate::collab::{AuthManager, AuthResult, PeerTracker, PeerState, PermissionManager};
use crate::history::EventHistory;
use crate::proto::amux;

pub struct DaemonServer {
    config: DaemonConfig,
    mqtt: MqttClient,
    agents: AgentManager,
    auth: AuthManager,
    peers: PeerTracker,
    permissions: PermissionManager,
    workspaces: WorkspaceStore,
    workspaces_path: PathBuf,
    sessions: SessionStore,
    sessions_path: PathBuf,
    history: EventHistory,
    teamclaw: Option<crate::teamclaw::SessionManager>,
}

impl DaemonServer {
    pub fn new(config: DaemonConfig, config_path: &std::path::Path) -> crate::error::Result<Self> {
        let mqtt = MqttClient::new(&config)?;

        let binary = config.agents.claude_code.as_ref()
            .map(|c| c.binary.clone())
            .unwrap_or_else(|| "claude".into());
        let flags = config.agents.claude_code.as_ref()
            .map(|c| c.default_flags.clone())
            .unwrap_or_default();

        // Members file is next to daemon.toml
        let members_path = config_path.parent()
            .unwrap_or(std::path::Path::new("."))
            .join("members.toml");
        let auth = AuthManager::new(members_path)?;
        let peers = PeerTracker::new();
        let permissions = PermissionManager::new();
        let agents = AgentManager::new(binary, flags);

        let workspaces_path = config_path.parent()
            .unwrap_or(std::path::Path::new("."))
            .join("workspaces.toml");
        let workspaces = WorkspaceStore::load(&workspaces_path)?;

        let sessions_path = config_path.parent()
            .unwrap_or(std::path::Path::new("."))
            .join("sessions.toml");
        let sessions = SessionStore::load(&sessions_path)?;

        let teamclaw = if let Some(team_id) = &config.team_id {
            let is_team_host = config.is_team_host.unwrap_or(false);
            Some(crate::teamclaw::SessionManager::new(
                mqtt.client.clone(),
                team_id,
                &config.device.id,
                crate::config::DaemonConfig::config_dir(),
                is_team_host,
                config.team_host_device_id.clone(),
            )?)
        } else {
            None
        };

        let history_dir = config_path.parent()
            .unwrap_or(std::path::Path::new("."))
            .join("history");
        let history = EventHistory::new(&history_dir);

        Ok(Self { config, mqtt, agents, auth, peers, permissions, workspaces, workspaces_path, sessions, sessions_path, history, teamclaw })
    }

    pub async fn run(mut self) -> crate::error::Result<()> {
        info!("amuxd v0.1.0 starting");

        // Poll until connected (CONNACK received)
        loop {
            match self.mqtt.eventloop.poll().await {
                Ok(Event::Incoming(Packet::ConnAck(_))) => {
                    info!("MQTT CONNACK received");
                    break;
                }
                Ok(_) => {}
                Err(e) => {
                    warn!("MQTT connect error: {}, retrying...", e);
                    tokio::time::sleep(tokio::time::Duration::from_secs(3)).await;
                }
            }
        }

        // Now connected — publish and subscribe
        self.mqtt.announce_online(&self.config.device.name).await
            .map_err(crate::error::AmuxError::Mqtt)?;
        self.mqtt.subscribe_all().await
            .map_err(crate::error::AmuxError::Mqtt)?;

        if let Some(tc) = &self.teamclaw {
            tc.subscribe_all().await.expect("teamclaw subscribe failed");
        }

        let publisher = Publisher::new(&self.mqtt);
        publisher.publish_agent_list(&self.merged_agent_list()).await
            .map_err(crate::error::AmuxError::Mqtt)?;
        publisher.publish_peer_list(&self.peers.to_proto_peer_list()).await
            .map_err(crate::error::AmuxError::Mqtt)?;
        publisher.publish_member_list(&self.auth.to_proto_member_list()).await
            .map_err(crate::error::AmuxError::Mqtt)?;
        publisher.publish_workspace_list(&self.workspaces.to_proto_list()).await
            .map_err(crate::error::AmuxError::Mqtt)?;

        info!(device_id = %self.config.device.id, "MQTT connected, listening for commands");

        // Main event loop
        loop {
            // Poll agent events (non-blocking drain)
            let agent_events = self.agents.poll_events();
            for (agent_id, acp_event) in agent_events {
                self.forward_agent_event(&agent_id, acp_event).await;
            }

            // Poll MQTT with a short timeout so we cycle back to check agents
            match tokio::time::timeout(
                tokio::time::Duration::from_millis(50),
                self.mqtt.eventloop.poll(),
            ).await {
                Ok(Ok(Event::Incoming(Packet::ConnAck(_)))) => {
                    // Reconnected — re-subscribe and re-publish all retained state
                    info!("MQTT reconnected, re-publishing state");
                    let _ = self.mqtt.announce_online(&self.config.device.name).await;
                    let _ = self.mqtt.subscribe_all().await;
                    if let Some(tc) = &self.teamclaw {
                        let _ = tc.subscribe_all().await;
                    }
                    let publisher = Publisher::new(&self.mqtt);
                    let _ = publisher.publish_agent_list(&self.merged_agent_list()).await;
                    let _ = publisher.publish_peer_list(&self.peers.to_proto_peer_list()).await;
                    let _ = publisher.publish_member_list(&self.auth.to_proto_member_list()).await;
                    let _ = publisher.publish_workspace_list(&self.workspaces.to_proto_list()).await;
                }
                Ok(Ok(Event::Incoming(Packet::Publish(publish)))) => {
                    if let Some(msg) = subscriber::parse_incoming(&publish) {
                        self.handle_incoming(msg).await;
                    }
                }
                Ok(Ok(_)) => {} // Other MQTT events
                Ok(Err(e)) => {
                    warn!("MQTT error: {}, reconnecting...", e);
                    tokio::time::sleep(tokio::time::Duration::from_secs(5)).await;
                }
                Err(_) => {} // Timeout — no MQTT event, loop back to check agents
            }
        }
    }

    /// Build merged agent list: active agents + historical (non-active) sessions
    fn merged_agent_list(&self) -> amux::AgentList {
        let mut agent_list = self.agents.to_proto_agent_list();
        let active_ids: std::collections::HashSet<String> = agent_list.agents.iter().map(|a| a.agent_id.clone()).collect();
        for session_info in self.sessions.to_proto_agent_list() {
            if !active_ids.contains(&session_info.agent_id) {
                agent_list.agents.push(session_info);
            }
        }
        agent_list
    }

    /// Forward an agent event to MQTT as an Envelope on the agent's events topic
    async fn forward_agent_event(&mut self, agent_id: &str, mut acp_event: amux::AcpEvent) {
        // Stamp the current model on agent-reply events (Output, Thinking) so iOS
        // bubbles can show which model produced the response. Other event types
        // (status changes, tool calls, permission requests, raw control messages)
        // are not model-attributable and stay empty. Safe to read current_model
        // here for the same reason as the collab publish path: the daemon event
        // loop is single-threaded, so no SetModel can interleave between the
        // agent's reply and this lookup.
        if matches!(
            acp_event.event,
            Some(amux::acp_event::Event::Output(_)) | Some(amux::acp_event::Event::Thinking(_))
        ) {
            if let Some(model) = self.agents.current_model(agent_id) {
                acp_event.model = model.clone();
            }
        }

        // Register permission requests for later resolution
        if let Some(amux::acp_event::Event::PermissionRequest(ref pr)) = acp_event.event {
            self.permissions.register_pending(&pr.request_id);
        }

        // Handle internal RawJson events (session_title, tool_title_update)
        if let Some(amux::acp_event::Event::Raw(ref raw)) = acp_event.event {
            if raw.method == "session_title" {
                let title = String::from_utf8_lossy(&raw.json_payload).to_string();
                if let Some(handle) = self.agents.get_handle_mut(agent_id) {
                    handle.session_title = title;
                    let publisher = Publisher::new(&self.mqtt);
                    let _ = publisher.publish_agent_list(&self.merged_agent_list()).await;
                }
                return;
            }
            if raw.method == "tool_title_update" {
                // Format: "tool_id|new_title"
                let payload = String::from_utf8_lossy(&raw.json_payload);
                if let Some((tool_id, new_title)) = payload.split_once('|') {
                    // Forward as a ToolUse event so iOS updates the tool name
                    let update_event = amux::AcpEvent {
                        event: Some(amux::acp_event::Event::Raw(amux::AcpRawJson {
                            method: "tool_title_update".into(),
                            json_payload: raw.json_payload.clone(),
                        })),
                        model: String::new(),
                    };
                    let seq = self.agents.get_handle_mut(agent_id).map(|h| h.next_sequence()).unwrap_or(0);
                    let envelope = amux::Envelope {
                        agent_id: agent_id.into(),
                        device_id: self.config.device.id.clone(),
                        source_peer_id: String::new(),
                        timestamp: chrono::Utc::now().timestamp(),
                        sequence: seq,
                        payload: Some(amux::envelope::Payload::AcpEvent(update_event)),
                    };
                    self.history.append(agent_id, &envelope);
                    let publisher = Publisher::new(&self.mqtt);
                    let _ = publisher.publish_agent_event(agent_id, &envelope).await;
                }
                return;
            }
        }

        // Update agent status if this is a status change event
        if let Some(amux::acp_event::Event::StatusChange(ref sc)) = acp_event.event {
            if let Some(handle) = self.agents.get_handle_mut(agent_id) {
                handle.status = amux::AgentStatus::try_from(sc.new_status).unwrap_or(amux::AgentStatus::Unknown);
            }
            if let Some(session) = self.sessions.find_by_id_mut(agent_id) {
                session.status = sc.new_status;
                let _ = self.sessions.save(&self.sessions_path);
            }
            let publisher = Publisher::new(&self.mqtt);
            let _ = publisher.publish_agent_list(&self.merged_agent_list()).await;
        }

        // Update session on complete output
        if let Some(amux::acp_event::Event::Output(ref output)) = acp_event.event {
            if output.is_complete {
                let summary: String = output.text.chars().take(200).collect();
                if let Some(handle) = self.agents.get_handle_mut(agent_id) {
                    handle.last_output_summary = summary.clone();
                }
                if let Some(session) = self.sessions.find_by_id_mut(agent_id) {
                    session.last_output_summary = summary;
                    let _ = self.sessions.save(&self.sessions_path);
                }
                // Publish completed output to collab sessions this agent participates in
                if let Some(tc) = &self.teamclaw {
                    let collab_sessions = tc.sessions_for_agent(agent_id);
                    // Safe to read current_model here: the daemon event loop is single-threaded and
                    // check_agent_busy prevents prompt overlap, so no SetModel can interleave between
                    // the agent's reply and this lookup. If those invariants change, capture the model
                    // at prompt arrival on the AcpEvent instead.
                    let model = self.agents.current_model(agent_id).cloned().unwrap_or_default();
                    for sid in &collab_sessions {
                        tc.publish_agent_message(sid, agent_id, &output.text, &model).await;
                    }
                }
            }
        }

        // Update session on tool use
        if let Some(amux::acp_event::Event::ToolUse(_)) = acp_event.event {
            if let Some(handle) = self.agents.get_handle_mut(agent_id) {
                handle.tool_use_count += 1;
            }
            if let Some(session) = self.sessions.find_by_id_mut(agent_id) {
                session.tool_use_count += 1;
                let _ = self.sessions.save(&self.sessions_path);
            }
        }

        let seq = self.agents.get_handle_mut(agent_id)
            .map(|h| h.next_sequence())
            .unwrap_or(0);

        // Ambient state variants (replaced wholesale on each push) should not
        // be persisted into the history buffer — replaying stale lists on
        // reconnect wastes bandwidth and contradicts the "in-memory only"
        // contract iOS assumes.
        let is_ambient = matches!(
            acp_event.event,
            Some(amux::acp_event::Event::AvailableCommands(_))
        );

        let envelope = amux::Envelope {
            agent_id: agent_id.into(),
            device_id: self.config.device.id.clone(),
            source_peer_id: String::new(), // agent-initiated
            timestamp: chrono::Utc::now().timestamp(),
            sequence: seq,
            payload: Some(amux::envelope::Payload::AcpEvent(acp_event)),
        };

        if !is_ambient {
            self.history.append(agent_id, &envelope);
        }
        let publisher = Publisher::new(&self.mqtt);
        if let Err(e) = publisher.publish_agent_event(agent_id, &envelope).await {
            warn!(agent_id, "failed to publish agent event: {}", e);
        }
    }

    async fn handle_incoming(&mut self, msg: subscriber::IncomingMessage) {
        use prost::Message as ProstMessage;
        match msg {
            subscriber::IncomingMessage::AgentCommand { agent_id, envelope } => {
                self.handle_agent_command(&agent_id, envelope).await;
            }
            subscriber::IncomingMessage::DeviceCollab { envelope } => {
                self.handle_device_collab(envelope).await;
            }
            subscriber::IncomingMessage::TeamclawRpc { topic, payload } => {
                // Pre-compute the host's primary agent_id so SessionManager
                // can stamp it onto any newly created session without needing
                // a back-reference into AgentManager.
                let primary = self.agents.first_running_agent_id();
                if let Some(tc) = &mut self.teamclaw {
                    tc.handle_rpc_request(&topic, &payload, primary).await;
                }
            }
            subscriber::IncomingMessage::TeamclawSessionMessage { session_id, payload } => {
                if let Ok(envelope) = crate::proto::teamclaw::SessionMessageEnvelope::decode(payload.as_slice()) {
                    if let Some(msg) = &envelope.message {
                        // Host persists the message
                        if let Some(tc) = &self.teamclaw {
                            if tc.is_host_for(&session_id) {
                                let _ = tc.persist_message(&session_id, msg);
                            }
                        }
                        // Route to local agents
                        if let Some(tc) = &self.teamclaw {
                            let activated = tc.agents_to_activate(&session_id, msg);
                            let desired_model = msg.model.clone();
                            for agent_actor_id in activated {
                                if msg.sender_actor_id == agent_actor_id { continue; }
                                if self.agents.get_handle(&agent_actor_id).is_some() {
                                    // If the message carries a model preference, switch
                                    // the agent to that model before sending the prompt.
                                    if !desired_model.is_empty() {
                                        let current = self.agents.current_model(&agent_actor_id).cloned().unwrap_or_default();
                                        if desired_model != current {
                                            if let Err(e) = self.agents.send_set_model(&agent_actor_id, &desired_model).await {
                                                warn!(?e, "send_set_model from collab message failed");
                                            } else {
                                                self.agents.set_current_model(&agent_actor_id, &desired_model);
                                                let publisher = Publisher::new(&self.mqtt);
                                                let _ = publisher.publish_agent_list(&self.merged_agent_list()).await;
                                            }
                                        }
                                    }
                                    let prompt = format!(
                                        "[Collab session: {}] {} says:\n{}",
                                        session_id, msg.sender_actor_id, msg.content
                                    );
                                    if let Err(e) = self.agents.send_prompt(&agent_actor_id, &prompt).await {
                                        warn!("Failed to route to agent {}: {}", agent_actor_id, e);
                                    }
                                }
                            }
                        }
                    }
                }
            }
            subscriber::IncomingMessage::TeamclawWorkItemEvent { session_id, payload } => {
                if let Ok(event) = crate::proto::teamclaw::WorkItemEvent::decode(payload.as_slice()) {
                    if let Some(tc) = &self.teamclaw {
                        let activated = tc.agents_to_activate_for_work_item(&session_id, &event);
                        for agent_actor_id in activated {
                            if self.agents.get_handle(&agent_actor_id).is_some() {
                                let prompt = format_work_item_prompt(&session_id, &event);
                                if !prompt.is_empty() {
                                    if let Err(e) = self.agents.send_prompt(&agent_actor_id, &prompt).await {
                                        warn!("Failed to route work item to agent {}: {}", agent_actor_id, e);
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    async fn handle_agent_command(&mut self, agent_id: &str, envelope: amux::CommandEnvelope) {
        let peer_id = envelope.peer_id.clone();
        let command_id = envelope.command_id.clone();
        let publisher = Publisher::new(&self.mqtt);

        let role = self.peers.get_peer(&peer_id)
            .map(|p| p.role)
            .unwrap_or_else(|| {
                // Peer not in memory (daemon restarted?) — try to match by token prefix
                // peer_id format: "ios-{token_prefix}" where token_prefix is first 6 chars of auth token
                let token_prefix = peer_id.strip_prefix("ios-").unwrap_or(&peer_id);
                self.auth.find_role_by_token_prefix(token_prefix)
                    .unwrap_or(amux::MemberRole::Member)
            });

        let acp_command = match envelope.acp_command {
            Some(c) => c,
            None => return,
        };
        let cmd = match acp_command.command {
            Some(c) => c,
            None => return,
        };

        // Check role permissions
        if let Err(reason) = self.permissions.check_command_permission(role, &cmd) {
            warn!(peer_id, %reason, "command rejected");
            // Publish rejection to device-level collab topic so all clients see it
            let reject_event = amux::DeviceCollabEvent {
                device_id: self.config.device.id.clone(),
                timestamp: chrono::Utc::now().timestamp(),
                event: Some(amux::device_collab_event::Event::CommandRejected(amux::PromptRejected {
                    command_id,
                    reason,
                })),
            };
            let _ = Publisher::new(&self.mqtt).publish_device_collab_event(&reject_event).await;
            return;
        }

        match cmd {
            amux::acp_command::Command::StartAgent(start) => {
                let at = amux::AgentType::try_from(start.agent_type).unwrap_or(amux::AgentType::ClaudeCode);

                // Resolve workspace path
                let (worktree, ws_id) = if !start.workspace_id.is_empty() {
                    match self.workspaces.find_by_id(&start.workspace_id) {
                        Some(ws) => (ws.path.clone(), ws.workspace_id.clone()),
                        None => {
                            error!(workspace_id = %start.workspace_id, "workspace not found");
                            return;
                        }
                    }
                } else {
                    let wt = if start.worktree.is_empty() { ".".to_string() } else { start.worktree.clone() };
                    (wt, String::new())
                };

                match self.agents.spawn_agent(at, &worktree, &start.initial_prompt, &ws_id).await {
                    Ok(new_id) => {
                        info!(agent_id = %new_id, peer_id, "agent started");
                        // Persist session
                        let acp_sid = self.agents.get_handle(&new_id)
                            .map(|h| h.acp_session_id.clone())
                            .unwrap_or_default();
                        let stored = StoredSession {
                            session_id: new_id.clone(),
                            acp_session_id: acp_sid,
                            agent_type: at as i32,
                            workspace_id: ws_id.clone(),
                            worktree: worktree.clone(),
                            status: amux::AgentStatus::Active as i32,
                            created_at: chrono::Utc::now().timestamp(),
                            last_prompt: start.initial_prompt.clone(),
                            last_output_summary: String::new(),
                            tool_use_count: 0,
                        };
                        self.sessions.upsert(stored);
                        let _ = self.sessions.save(&self.sessions_path);
                        let _ = publisher.publish_agent_list(&self.merged_agent_list()).await;
                        if let Some(info) = self.agents.to_proto_info(&new_id) {
                            let _ = publisher.publish_agent_state(&new_id, &info).await;
                        }
                    }
                    Err(e) => {
                        error!(peer_id, "failed to start agent: {}", e);
                    }
                }
            }

            amux::acp_command::Command::StopAgent(_) => {
                if self.agents.stop_agent(agent_id).await.is_some() {
                    if let Some(session) = self.sessions.find_by_id_mut(agent_id) {
                        session.status = amux::AgentStatus::Stopped as i32;
                        let _ = self.sessions.save(&self.sessions_path);
                    }
                    let _ = publisher.publish_agent_list(&self.merged_agent_list()).await;
                    info!(agent_id, peer_id, "agent stopped");
                }
            }

            amux::acp_command::Command::SendPrompt(prompt) => {
                // Lazy resume: if agent is not live but exists in session store,
                // spawn a new ACP process and resume the session.
                if self.agents.get_handle(agent_id).is_none() {
                    if let Some(stored) = self.sessions.find_by_id(agent_id) {
                        let at = amux::AgentType::try_from(stored.agent_type)
                            .unwrap_or(amux::AgentType::ClaudeCode);
                        let worktree = stored.worktree.clone();
                        let ws_id = stored.workspace_id.clone();
                        let acp_sid = stored.acp_session_id.clone();
                        info!(agent_id, "lazy-resuming historical session");
                        match self.agents.resume_agent(
                            agent_id, &acp_sid, at, &worktree, &ws_id, &prompt.text,
                        ).await {
                            Ok(new_acp_sid) => {
                                // Forward model_id if the client requested one
                                let desired_model = prompt.model_id.clone();
                                if !desired_model.is_empty() {
                                    match self.agents.send_set_model(agent_id, &desired_model).await {
                                        Ok(()) => {
                                            self.agents.set_current_model(agent_id, &desired_model);
                                        }
                                        Err(e) => {
                                            warn!(agent_id, model_id = %desired_model, "set_model after resume failed: {}", e);
                                        }
                                    }
                                }
                                // Update stored session with potentially new acp_session_id
                                if let Some(s) = self.sessions.find_by_id_mut(agent_id) {
                                    s.acp_session_id = new_acp_sid;
                                    s.status = amux::AgentStatus::Active as i32;
                                    s.last_prompt = prompt.text.clone();
                                }
                                let _ = self.sessions.save(&self.sessions_path);
                                info!(agent_id, peer_id, "session resumed, prompt sent");
                                self.publish_collab_event(agent_id, amux::CollabEvent {
                                    event: Some(amux::collab_event::Event::PromptAccepted(amux::PromptAccepted {
                                        command_id,
                                    })),
                                }).await;
                                let _ = publisher.publish_agent_list(&self.merged_agent_list()).await;
                            }
                            Err(e) => {
                                warn!(agent_id, "lazy resume failed: {}", e);
                                self.publish_collab_event(agent_id, amux::CollabEvent {
                                    event: Some(amux::collab_event::Event::PromptRejected(amux::PromptRejected {
                                        command_id,
                                        reason: format!("session resume failed: {}", e),
                                    })),
                                }).await;
                            }
                        }
                        return;
                    }
                }

                // Check busy
                if let Some(handle) = self.agents.get_handle(agent_id) {
                    if let Err(reason) = self.permissions.check_agent_busy(handle.status) {
                        self.publish_collab_event(agent_id, amux::CollabEvent {
                            event: Some(amux::collab_event::Event::PromptRejected(amux::PromptRejected {
                                command_id,
                                reason,
                            })),
                        }).await;
                        return;
                    }
                }

                // If the client requested a specific model and it differs from
                // the one we last applied, forward a SetModel command before
                // the prompt so the new turn runs on the requested model.
                let desired_model = prompt.model_id.clone();
                if !desired_model.is_empty() {
                    let current = self.agents.current_model(agent_id).cloned().unwrap_or_default();
                    if desired_model != current {
                        match self.agents.send_set_model(agent_id, &desired_model).await {
                            Ok(()) => {
                                self.agents.set_current_model(agent_id, &desired_model);
                                let _ = publisher.publish_agent_list(&self.merged_agent_list()).await;
                            }
                            Err(e) => {
                                warn!(agent_id, model_id = %desired_model, "send_set_model failed: {}", e);
                            }
                        }
                    }
                }

                // Send prompt to agent (respawns if process exited)
                match self.agents.send_prompt(agent_id, &prompt.text).await {
                    Ok(()) => {
                        if let Some(handle) = self.agents.get_handle_mut(agent_id) {
                            handle.status = amux::AgentStatus::Active;
                            handle.current_prompt = prompt.text.clone();
                        }
                        if let Some(session) = self.sessions.find_by_id_mut(agent_id) {
                            session.last_prompt = prompt.text.clone();
                            let _ = self.sessions.save(&self.sessions_path);
                        }
                        info!(agent_id, peer_id, "prompt sent to agent");
                        self.publish_collab_event(agent_id, amux::CollabEvent {
                            event: Some(amux::collab_event::Event::PromptAccepted(amux::PromptAccepted {
                                command_id,
                            })),
                        }).await;
                        let _ = publisher.publish_agent_list(&self.merged_agent_list()).await;
                    }
                    Err(e) => {
                        warn!(agent_id, "failed to send prompt: {}", e);
                    }
                }
            }

            amux::acp_command::Command::Cancel(_) => {
                match self.agents.cancel_agent(agent_id).await {
                    Ok(()) => {
                        if let Some(handle) = self.agents.get_handle_mut(agent_id) {
                            handle.status = amux::AgentStatus::Idle;
                        }
                        info!(agent_id, peer_id, "agent cancelled via ACP");
                        let _ = publisher.publish_agent_list(&self.merged_agent_list()).await;
                    }
                    Err(e) => {
                        warn!(agent_id, "failed to cancel agent: {}", e);
                    }
                }
            }

            amux::acp_command::Command::GrantPermission(grant) => {
                if self.permissions.try_resolve_permission(&grant.request_id) {
                    // Resolve via ACP permission response
                    let _ = self.agents.resolve_permission(agent_id, &grant.request_id, true).await;
                    info!(request_id = %grant.request_id, peer_id, "permission granted via ACP");
                    self.publish_collab_event(agent_id, amux::CollabEvent {
                        event: Some(amux::collab_event::Event::PermissionResolved(amux::PermissionResolved {
                            request_id: grant.request_id,
                            resolved_by_peer_id: peer_id,
                            granted: true,
                        })),
                    }).await;
                }
            }

            amux::acp_command::Command::DenyPermission(deny) => {
                if self.permissions.try_resolve_permission(&deny.request_id) {
                    // Resolve via ACP permission response
                    let _ = self.agents.resolve_permission(agent_id, &deny.request_id, false).await;
                    info!(request_id = %deny.request_id, peer_id, "permission denied via ACP");
                    self.publish_collab_event(agent_id, amux::CollabEvent {
                        event: Some(amux::collab_event::Event::PermissionResolved(amux::PermissionResolved {
                            request_id: deny.request_id,
                            resolved_by_peer_id: peer_id,
                            granted: false,
                        })),
                    }).await;
                }
            }

            amux::acp_command::Command::RequestHistory(req) => {
                use prost::Message;
                let page_size = if req.page_size == 0 { 50 } else { req.page_size };
                let (mut events, mut has_more) = self.history.read_page(agent_id, req.after_sequence, page_size);

                // HiveMQ Cloud free tier caps packet size at 10240 bytes.
                // Trim the batch by estimated encoded length so we never
                // produce a publish the broker will reject (which otherwise
                // forces the daemon's MQTT client to reconnect and knocks
                // every iOS peer offline in a loop).
                const HISTORY_BATCH_BUDGET: usize = 9500;
                while events.len() > 1 {
                    let estimate: usize = events.iter().map(|e| {
                        let n = e.encoded_len();
                        1 + prost::encoding::encoded_len_varint(n as u64) + n
                    }).sum::<usize>() + req.request_id.len() + 32;
                    if estimate < HISTORY_BATCH_BUDGET { break; }
                    events.pop();
                    has_more = true;
                }

                let next_seq = events.last().map(|e| e.sequence).unwrap_or(req.after_sequence);
                info!(agent_id, peer_id, after_seq = req.after_sequence, count = events.len(), has_more, "history requested");
                let batch = amux::HistoryBatch {
                    request_id: req.request_id,
                    events,
                    has_more,
                    next_after_sequence: next_seq,
                };
                self.publish_collab_event(agent_id, amux::CollabEvent {
                    event: Some(amux::collab_event::Event::HistoryBatch(batch)),
                }).await;
            }
        }
    }

    async fn handle_device_collab(&mut self, envelope: amux::DeviceCommandEnvelope) {
        let peer_id = envelope.peer_id.clone();
        let command_id = envelope.command_id.clone();
        let publisher = Publisher::new(&self.mqtt);

        let cmd = match envelope.command.and_then(|c| c.command) {
            Some(c) => c,
            None => return,
        };

        match cmd {
            amux::device_collab_command::Command::PeerAnnounce(announce) => {
                match self.auth.authenticate(&announce.auth_token) {
                    AuthResult::Accepted { member } => {
                        info!(peer_id, member_id = %member.member_id, "peer authenticated");
                        let pi = announce.peer.as_ref();
                        self.peers.add_peer(PeerState {
                            peer_id: pi.map(|p| p.peer_id.clone()).unwrap_or_default(),
                            member_id: member.member_id.clone(),
                            display_name: member.display_name.clone(),
                            device_type: pi.map(|p| p.device_type.clone()).unwrap_or_default(),
                            role: if member.is_owner() { amux::MemberRole::Owner } else { amux::MemberRole::Member },
                            connected_at: chrono::Utc::now().timestamp(),
                        });
                        // Publish all lists so the new peer gets current state
                        let _ = publisher.publish_peer_list(&self.peers.to_proto_peer_list()).await;
                        let _ = publisher.publish_member_list(&self.auth.to_proto_member_list()).await;
                        let _ = publisher.publish_workspace_list(&self.workspaces.to_proto_list()).await;
                        let _ = publisher.publish_agent_list(&self.merged_agent_list()).await;
                    }
                    AuthResult::Rejected { reason } => {
                        warn!(peer_id, %reason, "peer rejected");
                    }
                }
            }
            amux::device_collab_command::Command::PeerDisconnect(_) => {
                if self.peers.remove_peer(&peer_id).is_some() {
                    info!(peer_id, "peer disconnected");
                    let _ = publisher.publish_peer_list(&self.peers.to_proto_peer_list()).await;
                }
            }
            amux::device_collab_command::Command::InviteMember(invite) => {
                let role = self.peers.get_peer(&peer_id).map(|p| p.role).unwrap_or(amux::MemberRole::Member);
                if role != amux::MemberRole::Owner {
                    warn!(peer_id, "invite rejected: not owner");
                    let reject = amux::DeviceCollabEvent {
                        device_id: self.config.device.id.clone(),
                        timestamp: chrono::Utc::now().timestamp(),
                        event: Some(amux::device_collab_event::Event::CommandRejected(
                            amux::PromptRejected {
                                command_id,
                                reason: "Only owners can invite members".to_string(),
                            },
                        )),
                    };
                    let _ = publisher.publish_device_collab_event(&reject).await;
                    return;
                }
                let invite_role = if invite.role == amux::MemberRole::Owner as i32 { "owner" } else { "member" };
                match self.auth.create_invite(&invite.display_name, 24, invite_role) {
                    Ok(pending) => {
                        let deeplink = format!(
                            "amux://join?broker={}&device={}&token={}",
                            self.config.mqtt.broker_url, self.config.device.id, pending.invite_token
                        );
                        let event = amux::DeviceCollabEvent {
                            device_id: self.config.device.id.clone(),
                            timestamp: chrono::Utc::now().timestamp(),
                            event: Some(amux::device_collab_event::Event::InviteCreated(
                                amux::InviteCreated {
                                    request_id: invite.request_id,
                                    invite_token: pending.invite_token,
                                    deeplink,
                                    expires_at: pending.expires_at.timestamp(),
                                },
                            )),
                        };
                        let _ = publisher.publish_device_collab_event(&event).await;
                        info!("invite created for {}", invite.display_name);
                    }
                    Err(e) => {
                        error!("failed to create invite: {}", e);
                        let reject = amux::DeviceCollabEvent {
                            device_id: self.config.device.id.clone(),
                            timestamp: chrono::Utc::now().timestamp(),
                            event: Some(amux::device_collab_event::Event::CommandRejected(
                                amux::PromptRejected {
                                    command_id,
                                    reason: format!("Failed to create invite: {}", e),
                                },
                            )),
                        };
                        let _ = publisher.publish_device_collab_event(&reject).await;
                    }
                }
            }
            amux::device_collab_command::Command::RemoveMember(remove) => {
                let role = self.peers.get_peer(&peer_id).map(|p| p.role).unwrap_or(amux::MemberRole::Member);
                if role != amux::MemberRole::Owner {
                    warn!(peer_id, "remove rejected: not owner");
                    return;
                }
                if let Ok(true) = self.auth.remove_member(&remove.member_id) {
                    let kicked = self.peers.remove_by_member_id(&remove.member_id);
                    for p in &kicked {
                        info!(peer_id = %p.peer_id, "peer kicked");
                    }
                    let _ = publisher.publish_peer_list(&self.peers.to_proto_peer_list()).await;
                    let _ = publisher.publish_member_list(&self.auth.to_proto_member_list()).await;
                }
            }
            amux::device_collab_command::Command::AddWorkspace(add) => {
                match self.workspaces.add(&add.path) {
                    Ok(ws) => {
                        let _ = self.workspaces.save(&self.workspaces_path);
                        let _ = publisher.publish_workspace_list(&self.workspaces.to_proto_list()).await;
                        info!(workspace_id = %ws.workspace_id, path = %ws.path, "workspace added");
                        let event = amux::DeviceCollabEvent {
                            device_id: self.config.device.id.clone(),
                            timestamp: chrono::Utc::now().timestamp(),
                            event: Some(amux::device_collab_event::Event::WorkspaceResult(
                                amux::WorkspaceResult {
                                    command_id,
                                    success: true,
                                    error: String::new(),
                                    workspace: Some(amux::WorkspaceInfo {
                                        workspace_id: ws.workspace_id,
                                        path: ws.path,
                                        display_name: ws.display_name,
                                    }),
                                },
                            )),
                        };
                        let _ = publisher.publish_device_collab_event(&event).await;
                    }
                    Err(e) => {
                        warn!(path = %add.path, "add workspace failed: {}", e);
                        let event = amux::DeviceCollabEvent {
                            device_id: self.config.device.id.clone(),
                            timestamp: chrono::Utc::now().timestamp(),
                            event: Some(amux::device_collab_event::Event::WorkspaceResult(
                                amux::WorkspaceResult {
                                    command_id,
                                    success: false,
                                    error: e.to_string(),
                                    workspace: None,
                                },
                            )),
                        };
                        let _ = publisher.publish_device_collab_event(&event).await;
                    }
                }
            }
            amux::device_collab_command::Command::RemoveWorkspace(remove) => {
                if self.workspaces.remove(&remove.workspace_id) {
                    let _ = self.workspaces.save(&self.workspaces_path);
                    let _ = publisher.publish_workspace_list(&self.workspaces.to_proto_list()).await;
                    info!(workspace_id = %remove.workspace_id, "workspace removed");
                }
            }
        }
    }

    /// Publish a collab event on the agent's events topic
    async fn publish_collab_event(&self, agent_id: &str, event: amux::CollabEvent) {
        let envelope = amux::Envelope {
            agent_id: agent_id.into(),
            device_id: self.config.device.id.clone(),
            source_peer_id: String::new(),
            timestamp: chrono::Utc::now().timestamp(),
            sequence: 0,
            payload: Some(amux::envelope::Payload::CollabEvent(event)),
        };
        let publisher = Publisher::new(&self.mqtt);
        let _ = publisher.publish_agent_event(agent_id, &envelope).await;
    }
}

fn format_work_item_prompt(session_id: &str, event: &crate::proto::teamclaw::WorkItemEvent) -> String {
    use crate::proto::teamclaw::work_item_event::Event;
    match &event.event {
        Some(Event::Created(item)) => format!("[Collab session: {}] New work item: {} - {}", session_id, item.title, item.description),
        Some(Event::Updated(item)) => format!("[Collab session: {}] Work item updated: {}", session_id, item.title),
        Some(Event::Claimed(claim)) => format!("[Collab session: {}] Work item {} claimed by {}", session_id, claim.work_item_id, claim.actor_id),
        Some(Event::Submitted(sub)) => format!("[Collab session: {}] Submission for {}: {}", session_id, sub.work_item_id, sub.content),
        None => String::new(),
    }
}
