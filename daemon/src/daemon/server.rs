use rumqttc::{Event, Packet};
use tracing::{error, info, warn};

use crate::config::{DaemonConfig, MemberStore, SessionStore, StoredSession, WorkspaceStore};
use crate::mqtt::{MqttClient, publisher::Publisher, subscriber};
use crate::supabase::{SupabaseClient, SupabaseConfig};
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
    supabase: Option<SupabaseClient>,
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

        let workspaces_path = config_path.parent()
            .unwrap_or(std::path::Path::new("."))
            .join("workspaces.toml");
        let workspaces = WorkspaceStore::load(&workspaces_path)?;

        let sessions_path = config_path.parent()
            .unwrap_or(std::path::Path::new("."))
            .join("sessions.toml");
        let sessions = SessionStore::load(&sessions_path)?;

        let history_dir = config_path.parent()
            .unwrap_or(std::path::Path::new("."))
            .join("history");
        let history = EventHistory::new(&history_dir);

        // Load Supabase client if supabase.toml is present (absent = legacy mode).
        let supabase: Option<SupabaseClient> = match SupabaseConfig::default_path() {
            Ok(path) if path.exists() => {
                match SupabaseConfig::load(&path).and_then(SupabaseClient::new) {
                    Ok(c) => {
                        info!(
                            actor_id = %c.config().actor_id,
                            team_id = %c.config().team_id,
                            "Supabase client initialised"
                        );
                        Some(c)
                    }
                    Err(e) => {
                        warn!("Supabase config present but init failed: {e}");
                        None
                    }
                }
            }
            _ => {
                info!("No supabase.toml found; Supabase features disabled");
                None
            }
        };

        let agents = AgentManager::new(binary, flags, supabase.clone());

        let teamclaw = if let Some(team_id) = &config.team_id {
            Some(crate::teamclaw::SessionManager::new(
                mqtt.client.clone(),
                team_id,
                &config.device.id,
                supabase.as_ref().map(|c| c.config().actor_id.clone()),
                crate::config::DaemonConfig::config_dir(),
            )?)
        } else {
            None
        };

        Ok(Self { config, mqtt, agents, auth, peers, permissions, workspaces, workspaces_path, sessions, sessions_path, history, teamclaw, supabase })
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
        self.mqtt.subscribe_all().await
            .map_err(crate::error::AmuxError::Mqtt)?;

        if let Some(tc) = &mut self.teamclaw {
            tc.subscribe_all().await.expect("teamclaw subscribe failed");
        }

        self.register_startup_workspace().await;

        let publisher = Publisher::new(&self.mqtt);
        publisher.publish_device_state(&crate::proto::amux::DeviceState {
            online: true,
            device_name: self.config.device.name.clone(),
            timestamp: chrono::Utc::now().timestamp(),
        }).await.map_err(crate::error::AmuxError::Mqtt)?;
        publisher.publish_peer_list(&self.peers.to_proto_peer_list()).await
            .map_err(crate::error::AmuxError::Mqtt)?;
        publisher.publish_workspace_list(&self.workspaces.to_proto_list()).await
            .map_err(crate::error::AmuxError::Mqtt)?;
        self.publish_all_agent_states().await;

        info!(device_id = %self.config.device.id, "MQTT connected, listening for commands");

        // Register our MQTT device_id on the agents row so iOS clients can
        // route publishes at `amux/{device_id}/…` without typing the UUID.
        if let Some(sb) = self.supabase.clone() {
            let device_id = self.config.device.id.clone();
            tokio::spawn(async move {
                if let Err(e) = sb.set_agent_device_id(&device_id).await {
                    warn!("supabase agents.device_id upsert failed: {e}");
                }
            });
        }

        // Spawn 60s Supabase heartbeat task (no-op when supabase is None)
        if let Some(sb) = self.supabase.clone() {
            tokio::spawn(async move {
                let mut tick = tokio::time::interval(std::time::Duration::from_secs(60));
                tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
                loop {
                    tick.tick().await;
                    if let Err(e) = sb.heartbeat().await {
                        warn!("supabase heartbeat error: {e}");
                    }
                }
            });
        }

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
                    let _ = self.mqtt.subscribe_all().await;
                    if let Some(tc) = &mut self.teamclaw {
                        let _ = tc.subscribe_all().await;
                    }
                    let publisher = Publisher::new(&self.mqtt);
                    let _ = publisher.publish_device_state(&crate::proto::amux::DeviceState {
                        online: true,
                        device_name: self.config.device.name.clone(),
                        timestamp: chrono::Utc::now().timestamp(),
                    }).await;
                    let _ = publisher.publish_peer_list(&self.peers.to_proto_peer_list()).await;
                    let _ = publisher.publish_workspace_list(&self.workspaces.to_proto_list()).await;
                    self.publish_all_agent_states().await;
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

    async fn register_startup_workspace(&mut self) {
        let current_dir = match std::env::current_dir() {
            Ok(path) => path,
            Err(e) => {
                warn!("workspace auto-registration skipped: current_dir failed: {}", e);
                return;
            }
        };

        let startup_path = current_dir.to_string_lossy().to_string();
        match self.workspaces.add(&startup_path) {
            Ok(outcome) => {
                let mut workspace = outcome.workspace;
                let mut should_save = outcome.inserted;

                if self.sync_workspace_to_supabase(&mut workspace).await {
                    should_save = true;
                }

                if let Some(existing) = self.workspaces.workspaces.iter_mut().find(|w| w.workspace_id == workspace.workspace_id) {
                    *existing = workspace.clone();
                }

                if !should_save {
                    return;
                }

                if let Err(e) = self.workspaces.save(&self.workspaces_path) {
                    warn!(path = %startup_path, "workspace auto-registration save failed: {}", e);
                    return;
                }

                info!(
                    workspace_id = %workspace.workspace_id,
                    path = %workspace.path,
                    "startup workspace registered"
                );
            }
            Err(e) => {
                warn!(path = %startup_path, "workspace auto-registration failed: {}", e);
            }
        }
    }

    async fn sync_workspace_to_supabase(&self, workspace: &mut crate::config::StoredWorkspace) -> bool {
        let Some(sb) = &self.supabase else {
            return false;
        };

        let row = crate::supabase::WorkspaceUpsert {
            team_id: &sb.config().team_id,
            agent_id: &sb.config().actor_id,
            name: &workspace.display_name,
            path: if workspace.path.is_empty() { None } else { Some(workspace.path.as_str()) },
            archived: false,
        };

        match sb.upsert_workspace(&row).await {
            Ok(remote) => {
                if workspace.supabase_workspace_id == remote.id {
                    return false;
                }
                workspace.supabase_workspace_id = remote.id;
                true
            }
            Err(e) => {
                warn!(path = %workspace.path, "workspace supabase sync failed: {}", e);
                false
            }
        }
    }

    /// Build merged agent list: active agents + historical (non-active) sessions.
    /// Now only used by `publish_all_agent_states` to iterate startup/reconnect state.
    /// Per-agent updates should go through `publish_agent_state_by_id`.
    fn merged_agent_list(&self) -> amux::AgentList {
        let mut agent_list = self.agents.to_proto_agent_list();
        let active_ids: std::collections::HashSet<String> = agent_list.runtimes.iter().map(|a| a.runtime_id.clone()).collect();
        for session_info in self.sessions.to_proto_agent_list() {
            if !active_ids.contains(&session_info.runtime_id) {
                agent_list.runtimes.push(session_info);
            }
        }
        agent_list
    }

    /// Look up a single agent's current RuntimeInfo — live adapter first, then
    /// the historical session store. Returns `None` if unknown.
    fn agent_info_by_id(&self, agent_id: &str) -> Option<amux::RuntimeInfo> {
        self.agents
            .to_proto_info(agent_id)
            .or_else(|| self.sessions.to_proto_agent_info(agent_id))
    }

    /// Publish retained RuntimeInfo for a single agent on its per-agent state
    /// topic. Swallows errors (same convention as other publish helpers).
    async fn publish_agent_state_by_id(&self, agent_id: &str) {
        if let Some(info) = self.agent_info_by_id(agent_id) {
            let publisher = Publisher::new(&self.mqtt);
            let _ = publisher.publish_agent_state(agent_id, &info).await;
        }
    }

    /// Publish every known agent (active + historical) individually. Used on
    /// startup and after MQTT reconnect so clients subscribing to the wildcard
    /// `agent/+/state` topic receive one retained message per agent — keeping
    /// each publish small instead of relying on a large broker packet limit,
    /// which the old single-list publish would blow past once the session
    /// count grew.
    async fn publish_all_agent_states(&self) {
        let publisher = Publisher::new(&self.mqtt);
        for info in self.merged_agent_list().runtimes {
            let _ = publisher.publish_agent_state(&info.runtime_id, &info).await;
        }
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
                    self.publish_agent_state_by_id(agent_id).await;
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
                        runtime_id: agent_id.into(),
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
            self.publish_agent_state_by_id(agent_id).await;

            // Upsert agent_runtimes on status transitions
            if let Some(sb) = &self.supabase {
                let new_status = amux::AgentStatus::try_from(sc.new_status)
                    .unwrap_or(amux::AgentStatus::Unknown);
                let supabase_status: &'static str = match new_status {
                    amux::AgentStatus::Active => "running",
                    amux::AgentStatus::Idle => "idle",
                    amux::AgentStatus::Stopped => "stopped",
                    _ => "unknown",
                };
                let acp_sid = self.agents.get_handle(agent_id)
                    .map(|h| h.acp_session_id.clone())
                    .unwrap_or_default();
                let collab_session_id = self.agents.get_handle(agent_id)
                    .map(|h| h.collab_session_id.clone())
                    .unwrap_or_default();
                let ws_id = self.agents.get_handle(agent_id)
                    .map(|h| h.workspace_id.clone())
                    .unwrap_or_default();
                let supabase_ws_id = self.workspaces.find_by_id(&ws_id)
                    .and_then(|w| (!w.supabase_workspace_id.is_empty()).then_some(w.supabase_workspace_id.clone()));
                let current_model = self.agents.current_model(agent_id).cloned();
                let team_id = sb.config().team_id.clone();
                let actor_id = sb.config().actor_id.clone();
                let sb_clone = sb.clone();
                let now = chrono::Utc::now();
                tokio::spawn(async move {
                    let row = crate::supabase::AgentRuntimeUpsert {
                        team_id: &team_id,
                        agent_id: &actor_id,
                        session_id: (!collab_session_id.is_empty()).then_some(collab_session_id.as_str()),
                        workspace_id: supabase_ws_id.as_deref(),
                        backend_type: "claude",
                        backend_session_id: if acp_sid.is_empty() { None } else { Some(acp_sid.as_str()) },
                        status: supabase_status,
                        current_model: current_model.as_deref(),
                        last_seen_at: now,
                    };
                    if let Err(e) = sb_clone.upsert_agent_runtime(&row).await {
                        warn!("agent_runtimes upsert ({supabase_status}): {e}");
                    }
                });
            }
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

        // Keep publishes under a conservative 10 KB budget. Claude Code's
        // AvailableCommands list with full descriptions routinely lands at
        // ~12 KB, which can trip broker packet limits and knock the daemon's
        // MQTT session offline mid-session-start. Trim descriptions (and as a
        // last resort commands themselves) in-place until the envelope fits.
        if let Some(amux::acp_event::Event::AvailableCommands(ref mut ac)) = acp_event.event {
            fit_available_commands_in_budget(ac);
        }

        let envelope = amux::Envelope {
            runtime_id: agent_id.into(),
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

    /// Returns the primary (first running) agent ID for this daemon.
    /// Used to stamp new sessions with the host's agent without passing
    /// AgentManager into SessionManager.
    fn primary_agent_id(&self) -> Option<String> {
        self.agents.first_running_agent_id()
    }

    /// Server-level RPC dispatch. Decodes the wire payload, matches on Method,
    /// delegates session/task methods to SessionManager, and handles non-session
    /// methods locally. Publishes the response to the sender's rpc/res topic.
    async fn handle_rpc_request(&mut self, topic: &str, payload: &[u8]) {
        use crate::proto::teamclaw::{rpc_request::Method, RpcRequest, RpcResponse};
        use prost::Message as ProstMessage;

        let request = match RpcRequest::decode(payload) {
            Ok(r) => r,
            Err(e) => {
                warn!(%topic, "failed to decode RpcRequest: {}", e);
                return;
            }
        };

        let response: RpcResponse = match &request.method {
            // ─── Session/task methods — delegate to SessionManager ───
            Some(Method::CreateSession(_))
            | Some(Method::FetchSession(_))
            | Some(Method::FetchSessionMessages(_))
            | Some(Method::JoinSession(_))
            | Some(Method::AddParticipant(_))
            | Some(Method::RemoveParticipant(_))
            | Some(Method::CreateTask(_))
            | Some(Method::ClaimTask(_))
            | Some(Method::SubmitTask(_))
            | Some(Method::UpdateTask(_)) => {
                // Pre-compute primary before the mutable borrow of self.teamclaw.
                let primary = self.primary_agent_id();
                if let Some(tc) = self.teamclaw.as_mut() {
                    tc.handle_rpc_method(request.clone(), primary).await
                } else {
                    not_yet_implemented(&request, "session_manager not initialized")
                }
            }
            // ─── Non-session methods — handle locally ───
            // Phase 1b Tasks 3-9 replace these stubs with real handlers.
            Some(Method::FetchPeers(_)) => self.handle_fetch_peers(&request).await,
            Some(Method::FetchWorkspaces(_)) => self.handle_fetch_workspaces(&request).await,
            Some(Method::AnnouncePeer(ann)) => self.handle_announce_peer(&request, ann).await,
            Some(Method::DisconnectPeer(d)) => self.handle_disconnect_peer(&request, d).await,
            Some(Method::AddWorkspace(a)) => self.handle_add_workspace(&request, a).await,
            Some(Method::RemoveWorkspace(r)) => self.handle_remove_workspace(&request, r).await,
            Some(Method::RemoveMember(_)) => not_yet_implemented(&request, "remove_member"),
            Some(Method::RuntimeStop(_)) => not_yet_implemented(&request, "runtime_stop"),
            Some(Method::RuntimeStart(_)) => not_yet_implemented(&request, "runtime_start"),
            None => RpcResponse {
                request_id: request.request_id.clone(),
                success: false,
                error: "no method".to_string(),
                requester_client_id: request.requester_client_id.clone(),
                requester_actor_id: request.requester_actor_id.clone(),
                requester_device_id: request.requester_device_id.clone(),
                result: None,
            },
        };

        // Publish response on the sender's rpc/res topic (mirrors RpcServer::respond).
        let res_topic = self.mqtt.topics.rpc_res_for(&request.sender_device_id);
        let bytes = response.encode_to_vec();
        if let Err(e) = self
            .mqtt
            .client
            .publish(res_topic, rumqttc::QoS::AtLeastOnce, false, bytes)
            .await
        {
            warn!("failed to publish RpcResponse: {}", e);
        }
    }

    async fn handle_incoming(&mut self, msg: subscriber::IncomingMessage) {
        use prost::Message as ProstMessage;
        match msg {
            subscriber::IncomingMessage::AgentCommand { agent_id, envelope } => {
                self.handle_agent_command(&agent_id, envelope).await;
            }
            subscriber::IncomingMessage::RuntimeCommand { runtime_id, envelope } => {
                // During Phase 1-2, runtime_id on the new path is the same
                // 8-char UUID used on the legacy path. Route into the same
                // ACP handler as AgentCommand by translating the envelope.
                let legacy_envelope = amux::CommandEnvelope {
                    runtime_id: envelope.runtime_id,
                    device_id: envelope.device_id,
                    peer_id: envelope.peer_id,
                    command_id: envelope.command_id,
                    timestamp: envelope.timestamp,
                    sender_actor_id: envelope.sender_actor_id,
                    reply_to_device_id: envelope.reply_to_device_id,
                    acp_command: envelope.acp_command,
                };
                self.handle_agent_command(&runtime_id, legacy_envelope).await;
            }
            subscriber::IncomingMessage::DeviceCollab { envelope } => {
                self.handle_device_collab(envelope).await;
            }
            subscriber::IncomingMessage::TeamclawRpc { topic, payload } => {
                self.handle_rpc_request(&topic, &payload).await;
            }
            subscriber::IncomingMessage::TeamclawSessionLive { session_id, payload } => {
                if let Ok(envelope) = crate::proto::teamclaw::LiveEventEnvelope::decode(payload.as_slice()) {
                    match envelope.event_type.as_str() {
                        "message.created" => {
                            if let Ok(message_envelope) =
                                crate::proto::teamclaw::SessionMessageEnvelope::decode(envelope.body.as_slice())
                            {
                                if let Some(msg) = &message_envelope.message {
                                    if let Some(tc) = &mut self.teamclaw {
                                        if !tc.should_process_message(&session_id, &msg.message_id) {
                                            return;
                                        }
                                    }
                                    if let Some(tc) = &self.teamclaw {
                                        let _ = tc.persist_message(&session_id, msg).await;
                                    }
                                    if let Some(tc) = &self.teamclaw {
                                        let activated = tc.agents_to_activate(&session_id, msg);
                                        let desired_model = msg.model.clone();
                                        for agent_actor_id in activated {
                                            if msg.sender_actor_id == agent_actor_id { continue; }
                                            if self.agents.get_handle(&agent_actor_id).is_some() {
                                                if !desired_model.is_empty() {
                                                    let current = self.agents.current_model(&agent_actor_id).cloned().unwrap_or_default();
                                                    if desired_model != current {
                                                        if let Err(e) = self.agents.send_set_model(&agent_actor_id, &desired_model).await {
                                                            warn!(?e, "send_set_model from live message failed");
                                                        } else {
                                                            self.agents.set_current_model(&agent_actor_id, &desired_model);
                                                            self.publish_agent_state_by_id(&agent_actor_id).await;
                                                        }
                                                    }
                                                }
                                                let prompt = format!(
                                                    "[Collab session: {}] {} says:\n{}",
                                                    session_id, msg.sender_actor_id, msg.content
                                                );
                                                if let Err(e) = self.agents.send_prompt(&agent_actor_id, &prompt).await {
                                                    warn!("Failed to route live message to agent {}: {}", agent_actor_id, e);
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        "task.created" | "task.updated" => {
                            if let Ok(event) = crate::proto::teamclaw::TaskEvent::decode(envelope.body.as_slice()) {
                                if let Some(tc) = &mut self.teamclaw {
                                    if !tc.should_process_task_event(&session_id, &event) {
                                        return;
                                    }
                                }
                                if let Some(tc) = &self.teamclaw {
                                    let activated = tc.agents_to_activate_for_work_item(&session_id, &event);
                                    for agent_actor_id in activated {
                                        if self.agents.get_handle(&agent_actor_id).is_some() {
                                            let prompt = format_task_prompt(&session_id, &event);
                                            if !prompt.is_empty() {
                                                if let Err(e) = self.agents.send_prompt(&agent_actor_id, &prompt).await {
                                                    warn!("Failed to route live task to agent {}: {}", agent_actor_id, e);
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        _ => {}
                    }
                }
            }
            subscriber::IncomingMessage::TeamclawNotify { device_id: _, payload } => {
                if let Ok(envelope) = crate::proto::teamclaw::NotifyEnvelope::decode(payload.as_slice()) {
                    if envelope.event_type == "membership.refresh" && !envelope.session_id.is_empty() {
                        if let Some(tc) = &mut self.teamclaw {
                            if let Err(err) = tc.refresh_membership_subscriptions().await {
                                warn!(?err, session_id = %envelope.session_id, "failed to refresh membership subscriptions after notify");
                            }
                        }
                    }
                }
            }
        }
    }

    /// Derive the caller's MemberRole, preferring a Supabase
    /// `agent_member_access` lookup keyed on (our own agent actor id,
    /// envelope's sender_actor_id) and falling back to the MQTT-era
    /// peer/token role when the Supabase side isn't available.
    async fn resolve_role(&mut self, sender_actor_id: &str, peer_id: &str) -> amux::MemberRole {
        if !sender_actor_id.is_empty() {
            if let Some(sb) = &self.supabase {
                let my_agent_id = sb.config().actor_id.clone();
                match sb.check_agent_permission(&my_agent_id, sender_actor_id).await {
                    Ok(Some(level)) => {
                        return match level.as_str() {
                            "admin" => amux::MemberRole::Owner,
                            "write" => amux::MemberRole::Member,
                            _ => amux::MemberRole::Member,
                        };
                    }
                    Ok(None) => {
                        warn!(actor_id = %sender_actor_id, "no agent_member_access grant");
                        return amux::MemberRole::Member;
                    }
                    Err(e) => {
                        warn!(%e, "supabase permission check failed; falling back to peer role");
                    }
                }
            }
        }

        self.peers.get_peer(peer_id)
            .map(|p| p.role)
            .unwrap_or_else(|| {
                let token_prefix = peer_id
                    .strip_prefix("ios-")
                    .or_else(|| peer_id.strip_prefix("mac-"))
                    .unwrap_or(peer_id);
                self.auth.find_role_by_token_prefix(token_prefix)
                    .unwrap_or(amux::MemberRole::Member)
            })
    }

    async fn handle_agent_command(&mut self, agent_id: &str, envelope: amux::CommandEnvelope) {
        let peer_id = envelope.peer_id.clone();
        let command_id = envelope.command_id.clone();
        let sender_actor_id = envelope.sender_actor_id.clone();
        let reply_device_id = if envelope.reply_to_device_id.is_empty() {
            envelope.device_id.clone()
        } else {
            envelope.reply_to_device_id.clone()
        };

        let acp_command = match envelope.acp_command {
            Some(c) => c,
            None => return,
        };
        let cmd = match acp_command.command {
            Some(c) => c,
            None => return,
        };

        // Permission check.
        // Preferred path: iOS sets `sender_actor_id` on the envelope, daemon
        // looks up `agent_member_access.permission_level` in Supabase and
        // reduces that to a MemberRole. Legacy path: fall back to the
        // peer's MQTT-era role when the Supabase lookup is unavailable.
        let role = self.resolve_role(&sender_actor_id, &peer_id).await;

        if let Err(reason) = self.permissions.check_command_permission(role, &cmd) {
            warn!(peer_id, %reason, "command rejected");
            self.publish_command_rejected(&reply_device_id, command_id, reason).await;
            return;
        }

        match cmd {
            amux::acp_command::Command::StartAgent(start) => {
                let at = amux::AgentType::try_from(start.agent_type).unwrap_or(amux::AgentType::ClaudeCode);

                // Resolve workspace path. Two sources in order of priority:
                //   1. Local workspaces.toml lookup by legacy MQTT id (id set,
                //      path comes from the registry).
                //   2. Supabase-sourced envelope: id is the Supabase UUID and
                //      `worktree` carries the checkout path. The daemon uses
                //      the path directly and keeps the UUID around for
                //      `agent_runtimes.workspace_id`.
                let start_workspace_id = start.workspace_id.clone();
                let start_worktree = start.worktree.clone();
                let start_session_id = start.session_id.clone();
                info!(
                    workspace_id = %start_workspace_id,
                    worktree = %start_worktree,
                    peer_id,
                    "received startAgent envelope"
                );
                let (worktree, ws_id, supabase_ws_id_owned): (String, String, Option<String>) =
                    if !start_workspace_id.is_empty() {
                        if let Some(ws) = self.workspaces.find_by_id(&start_workspace_id) {
                            (
                                ws.path.clone(),
                                ws.workspace_id.clone(),
                                (!ws.supabase_workspace_id.is_empty())
                                    .then_some(ws.supabase_workspace_id.clone()),
                            )
                        } else if !start_worktree.is_empty() {
                            (start_worktree.clone(), String::new(), Some(start_workspace_id.clone()))
                        } else {
                            let reason = format!(
                                "workspace {} not found and no worktree path provided",
                                start_workspace_id
                            );
                            error!(
                                workspace_id = %start_workspace_id,
                                %reason,
                                "startAgent rejected"
                            );
                            self.publish_command_rejected(&reply_device_id, command_id.clone(), reason).await;
                            return;
                        }
                    } else {
                        let wt = if start_worktree.is_empty() { ".".to_string() } else { start_worktree.clone() };
                        (wt, String::new(), None)
                    };
                let supabase_ws_id = supabase_ws_id_owned.as_deref();

                match self.agents.spawn_agent(
                    at,
                    &worktree,
                    &start.initial_prompt,
                    &ws_id,
                    supabase_ws_id,
                    (!start_session_id.is_empty()).then_some(start_session_id.as_str()),
                ).await {
                    Ok(new_id) => {
                        info!(agent_id = %new_id, peer_id, "agent started");
                        // Persist session
                        let acp_sid = self.agents.get_handle(&new_id)
                            .map(|h| h.acp_session_id.clone())
                            .unwrap_or_default();
                        let stored = StoredSession {
                            session_id: new_id.clone(),
                            acp_session_id: acp_sid,
                            collab_session_id: start_session_id.clone(),
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
                        self.publish_agent_state_by_id(&new_id).await;
                        self.publish_agent_start_result(
                            &reply_device_id,
                            command_id.clone(),
                            true,
                            String::new(),
                            new_id.clone(),
                            start_session_id.clone(),
                        ).await;
                    }
                    Err(e) => {
                        let reason = format!("Failed to start agent: {}", e);
                        error!(peer_id, "{}", reason);
                        self.publish_agent_start_result(
                            &reply_device_id,
                            command_id.clone(),
                            false,
                            reason,
                            String::new(),
                            start_session_id.clone(),
                        ).await;
                    }
                }
            }

            amux::acp_command::Command::StopAgent(_) => {
                if self.agents.stop_agent(agent_id).await.is_some() {
                    if let Some(session) = self.sessions.find_by_id_mut(agent_id) {
                        session.status = amux::AgentStatus::Stopped as i32;
                        let _ = self.sessions.save(&self.sessions_path);
                    }
                    self.publish_agent_state_by_id(agent_id).await;
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
                        let collab_session_id = stored.collab_session_id.clone();
                        info!(agent_id, "lazy-resuming historical session");
                        let supabase_ws_id = self.workspaces.find_by_id(&ws_id)
                            .and_then(|w| (!w.supabase_workspace_id.is_empty()).then_some(w.supabase_workspace_id.as_str()));
                        match self.agents.resume_agent(
                            agent_id,
                            &acp_sid,
                            at,
                            &worktree,
                            &ws_id,
                            supabase_ws_id,
                            (!collab_session_id.is_empty()).then_some(collab_session_id.as_str()),
                            &prompt.text,
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
                                    s.collab_session_id = collab_session_id.clone();
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
                                self.publish_agent_state_by_id(agent_id).await;
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
                                self.publish_agent_state_by_id(agent_id).await;
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
                        self.publish_agent_state_by_id(agent_id).await;
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
                        self.publish_agent_state_by_id(agent_id).await;
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

                // Keep history replies under a conservative 10 KB publish
                // budget. Trim the batch by estimated encoded length so we never
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

        let cmd = match envelope.command.and_then(|c| c.command) {
            Some(c) => c,
            None => return,
        };

        match cmd {
            amux::device_collab_command::Command::PeerAnnounce(announce) => {
                let (accepted, _error, _role) = self.apply_peer_announce(&announce).await;
                if accepted {
                    // Legacy behavior: new peer sees current state via retained
                    // peer_list / workspace_list publishes. Phase 3 replaces
                    // these with FetchPeers/FetchWorkspaces RPC + notify.
                    let publisher = Publisher::new(&self.mqtt);
                    let _ = publisher.publish_peer_list(&self.peers.to_proto_peer_list()).await;
                    let _ = publisher.publish_workspace_list(&self.workspaces.to_proto_list()).await;
                }
            }
            amux::device_collab_command::Command::PeerDisconnect(_) => {
                let (accepted, _error) = self.apply_peer_disconnect(&peer_id).await;
                if accepted {
                    let publisher = Publisher::new(&self.mqtt);
                    let _ = publisher.publish_peer_list(&self.peers.to_proto_peer_list()).await;
                }
            }
            amux::device_collab_command::Command::InviteMember(_invite) => {
                // Legacy MQTT invite flow removed. Invites are now issued via
                // the Supabase create_team_invite RPC from iOS directly.
                warn!(peer_id, "InviteMember command received but handler removed; use Supabase invite flow");
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
                    let publisher = Publisher::new(&self.mqtt);
                    let _ = publisher.publish_peer_list(&self.peers.to_proto_peer_list()).await;
                }
            }
            amux::device_collab_command::Command::AddWorkspace(add) => {
                let (success, error, workspace) = self.apply_add_workspace(&add).await;
                let publisher = Publisher::new(&self.mqtt);
                let _ = publisher
                    .publish_workspace_list(&self.workspaces.to_proto_list())
                    .await;
                let event = amux::DeviceCollabEvent {
                    device_id: self.config.device.id.clone(),
                    timestamp: chrono::Utc::now().timestamp(),
                    event: Some(amux::device_collab_event::Event::WorkspaceResult(
                        amux::WorkspaceResult {
                            command_id,
                            success,
                            error,
                            workspace,
                        },
                    )),
                };
                let _ = publisher.publish_device_collab_event(&event).await;
            }
            amux::device_collab_command::Command::RemoveWorkspace(remove) => {
                let (success, _error) = self.apply_remove_workspace(&remove).await;
                if success {
                    let publisher = Publisher::new(&self.mqtt);
                    let _ = publisher
                        .publish_workspace_list(&self.workspaces.to_proto_list())
                        .await;
                }
            }
        }
    }

    /// Publish a collab event on the agent's events topic
    async fn publish_collab_event(&self, agent_id: &str, event: amux::CollabEvent) {
        let envelope = amux::Envelope {
            runtime_id: agent_id.into(),
            device_id: self.config.device.id.clone(),
            source_peer_id: String::new(),
            timestamp: chrono::Utc::now().timestamp(),
            sequence: 0,
            payload: Some(amux::envelope::Payload::CollabEvent(event)),
        };
        let publisher = Publisher::new(&self.mqtt);
        let _ = publisher.publish_agent_event(agent_id, &envelope).await;
    }

    async fn publish_command_rejected(&self, reply_device_id: &str, command_id: String, reason: String) {
        info!(
            reply_device_id = %reply_device_id,
            command_id = %command_id,
            reason = %reason,
            "publishing command rejected event"
        );
        let reject_event = command_rejected_event(reply_device_id, command_id, reason);
        let _ = Publisher::new(&self.mqtt)
            .publish_device_collab_event_to(reply_device_id, &reject_event)
            .await;
    }

    async fn publish_agent_start_result(
        &self,
        reply_device_id: &str,
        command_id: String,
        success: bool,
        error: String,
        agent_id: String,
        session_id: String,
    ) {
        info!(
            reply_device_id = %reply_device_id,
            command_id = %command_id,
            success,
            error = %error,
            agent_id = %agent_id,
            session_id = %session_id,
            "publishing agent start result"
        );
        let event = agent_start_result_event(
            reply_device_id,
            command_id,
            success,
            error,
            agent_id,
            session_id,
        );
        let _ = Publisher::new(&self.mqtt)
            .publish_device_collab_event_to(reply_device_id, &event)
            .await;
    }

    // ─── Non-session RPC handlers ───

    async fn handle_fetch_peers(
        &self,
        request: &crate::proto::teamclaw::RpcRequest,
    ) -> crate::proto::teamclaw::RpcResponse {
        use crate::proto::teamclaw::{rpc_response, FetchPeersResult, RpcResponse};

        let peers = self.peers.to_proto_peer_list().peers;
        RpcResponse {
            request_id: request.request_id.clone(),
            success: true,
            error: String::new(),
            requester_client_id: request.requester_client_id.clone(),
            requester_actor_id: request.requester_actor_id.clone(),
            requester_device_id: request.requester_device_id.clone(),
            result: Some(rpc_response::Result::FetchPeersResult(FetchPeersResult {
                peers,
            })),
        }
    }

    async fn handle_fetch_workspaces(
        &self,
        request: &crate::proto::teamclaw::RpcRequest,
    ) -> crate::proto::teamclaw::RpcResponse {
        use crate::proto::teamclaw::{rpc_response, FetchWorkspacesResult, RpcResponse};

        let workspaces = self.workspaces.to_proto_list().workspaces;
        RpcResponse {
            request_id: request.request_id.clone(),
            success: true,
            error: String::new(),
            requester_client_id: request.requester_client_id.clone(),
            requester_actor_id: request.requester_actor_id.clone(),
            requester_device_id: request.requester_device_id.clone(),
            result: Some(rpc_response::Result::FetchWorkspacesResult(
                FetchWorkspacesResult { workspaces },
            )),
        }
    }

    // ─── Peer mutation helpers (shared by legacy collab path + RPC handlers) ───

    /// Authenticates and adds a peer. Returns (accepted, error_text, assigned_role).
    /// Does NOT publish anything — the caller is responsible for any broadcasts
    /// (legacy collab arm republishes peer_list + workspace_list; RPC handler
    /// publishes Notify "peers.changed").
    async fn apply_peer_announce(
        &mut self,
        announce: &amux::PeerAnnounce,
    ) -> (bool, String, amux::MemberRole) {
        match self.auth.authenticate(&announce.auth_token) {
            AuthResult::Accepted { member } => {
                let role = if member.is_owner() {
                    amux::MemberRole::Owner
                } else {
                    amux::MemberRole::Member
                };
                let pi = announce.peer.as_ref();
                let peer_id_str = pi.map(|p| p.peer_id.clone()).unwrap_or_default();
                info!(peer_id = %peer_id_str, member_id = %member.member_id, "peer authenticated");
                self.peers.add_peer(PeerState {
                    peer_id: peer_id_str,
                    member_id: member.member_id.clone(),
                    display_name: member.display_name.clone(),
                    device_type: pi.map(|p| p.device_type.clone()).unwrap_or_default(),
                    role,
                    connected_at: chrono::Utc::now().timestamp(),
                });
                (true, String::new(), role)
            }
            AuthResult::Rejected { reason } => {
                warn!(%reason, "peer rejected");
                (false, reason, amux::MemberRole::Member)
            }
        }
    }

    /// Removes a peer by peer_id. Returns (accepted, error_text).
    /// Does NOT publish anything — the caller is responsible for any broadcasts.
    async fn apply_peer_disconnect(&mut self, peer_id: &str) -> (bool, String) {
        if self.peers.remove_peer(peer_id).is_some() {
            info!(peer_id, "peer disconnected");
            (true, String::new())
        } else {
            (false, format!("unknown peer_id: {}", peer_id))
        }
    }

    // ─── AnnouncePeer / DisconnectPeer RPC handlers ───

    async fn handle_announce_peer(
        &mut self,
        request: &crate::proto::teamclaw::RpcRequest,
        announce: &crate::proto::teamclaw::AnnouncePeerRequest,
    ) -> crate::proto::teamclaw::RpcResponse {
        use crate::proto::teamclaw::{rpc_response, AnnouncePeerResult, RpcResponse};

        // Construct amux::PeerAnnounce that apply_peer_announce expects.
        let amux_announce = amux::PeerAnnounce {
            peer: announce.peer.clone(),
            auth_token: announce.auth_token.clone(),
        };
        let (accepted, error, assigned_role) = self.apply_peer_announce(&amux_announce).await;

        // Hint subscribers to re-fetch peers.
        if accepted {
            let publisher = Publisher::new(&self.mqtt);
            let _ = publisher.publish_notify("peers.changed", "").await;
        }

        RpcResponse {
            request_id: request.request_id.clone(),
            success: accepted,
            error: error.clone(),
            requester_client_id: request.requester_client_id.clone(),
            requester_actor_id: request.requester_actor_id.clone(),
            requester_device_id: request.requester_device_id.clone(),
            result: Some(rpc_response::Result::AnnouncePeerResult(AnnouncePeerResult {
                accepted,
                error,
                assigned_role: assigned_role as i32,
            })),
        }
    }

    async fn handle_disconnect_peer(
        &mut self,
        request: &crate::proto::teamclaw::RpcRequest,
        disconnect: &crate::proto::teamclaw::DisconnectPeerRequest,
    ) -> crate::proto::teamclaw::RpcResponse {
        use crate::proto::teamclaw::{rpc_response, DisconnectPeerResult, RpcResponse};

        let (accepted, error) = self.apply_peer_disconnect(&disconnect.peer_id).await;

        if accepted {
            let publisher = Publisher::new(&self.mqtt);
            let _ = publisher.publish_notify("peers.changed", "").await;
        }

        RpcResponse {
            request_id: request.request_id.clone(),
            success: accepted,
            error: error.clone(),
            requester_client_id: request.requester_client_id.clone(),
            requester_actor_id: request.requester_actor_id.clone(),
            requester_device_id: request.requester_device_id.clone(),
            result: Some(rpc_response::Result::DisconnectPeerResult(DisconnectPeerResult {
                accepted,
                error,
            })),
        }
    }

    /// Applies a workspace add. Returns (success, error_text, resulting_workspace_if_any).
    /// Caller publishes any collab event or Notify hint.
    async fn apply_add_workspace(
        &mut self,
        add: &amux::AddWorkspace,
    ) -> (bool, String, Option<amux::WorkspaceInfo>) {
        match self.workspaces.add(&add.path) {
            Ok(outcome) => {
                let mut ws = outcome.workspace;
                let mut should_save = outcome.inserted;
                if self.sync_workspace_to_supabase(&mut ws).await {
                    should_save = true;
                }
                if let Some(existing) = self
                    .workspaces
                    .workspaces
                    .iter_mut()
                    .find(|w| w.workspace_id == ws.workspace_id)
                {
                    *existing = ws.clone();
                }
                if should_save {
                    let _ = self.workspaces.save(&self.workspaces_path);
                }
                info!(workspace_id = %ws.workspace_id, path = %ws.path, "workspace added");
                let info = amux::WorkspaceInfo {
                    workspace_id: ws.workspace_id,
                    path: ws.path,
                    display_name: ws.display_name,
                };
                (true, String::new(), Some(info))
            }
            Err(e) => {
                warn!(path = %add.path, "add workspace failed: {}", e);
                (false, e.to_string(), None)
            }
        }
    }

    /// Applies a workspace remove. Returns (success, error_text).
    async fn apply_remove_workspace(
        &mut self,
        remove: &amux::RemoveWorkspace,
    ) -> (bool, String) {
        if self.workspaces.remove(&remove.workspace_id) {
            let _ = self.workspaces.save(&self.workspaces_path);
            info!(workspace_id = %remove.workspace_id, "workspace removed");
            (true, String::new())
        } else {
            (false, format!("unknown workspace_id: {}", remove.workspace_id))
        }
    }

    async fn handle_add_workspace(
        &mut self,
        request: &crate::proto::teamclaw::RpcRequest,
        add: &crate::proto::teamclaw::AddWorkspaceRequest,
    ) -> crate::proto::teamclaw::RpcResponse {
        use crate::proto::teamclaw::{rpc_response, AddWorkspaceResult, RpcResponse};

        let amux_add = amux::AddWorkspace { path: add.path.clone() };
        let (accepted, error, workspace) = self.apply_add_workspace(&amux_add).await;

        if accepted {
            let publisher = Publisher::new(&self.mqtt);
            let _ = publisher.publish_workspace_list(&self.workspaces.to_proto_list()).await;
            let _ = publisher.publish_notify("workspaces.changed", "").await;
        }

        RpcResponse {
            request_id: request.request_id.clone(),
            success: accepted,
            error: error.clone(),
            requester_client_id: request.requester_client_id.clone(),
            requester_actor_id: request.requester_actor_id.clone(),
            requester_device_id: request.requester_device_id.clone(),
            result: Some(rpc_response::Result::AddWorkspaceResult(AddWorkspaceResult {
                accepted,
                error,
                workspace,
            })),
        }
    }

    async fn handle_remove_workspace(
        &mut self,
        request: &crate::proto::teamclaw::RpcRequest,
        remove: &crate::proto::teamclaw::RemoveWorkspaceRequest,
    ) -> crate::proto::teamclaw::RpcResponse {
        use crate::proto::teamclaw::{rpc_response, RemoveWorkspaceResult, RpcResponse};

        let amux_remove = amux::RemoveWorkspace { workspace_id: remove.workspace_id.clone() };
        let (accepted, error) = self.apply_remove_workspace(&amux_remove).await;

        if accepted {
            let publisher = Publisher::new(&self.mqtt);
            let _ = publisher.publish_workspace_list(&self.workspaces.to_proto_list()).await;
            let _ = publisher.publish_notify("workspaces.changed", "").await;
        }

        RpcResponse {
            request_id: request.request_id.clone(),
            success: accepted,
            error: error.clone(),
            requester_client_id: request.requester_client_id.clone(),
            requester_actor_id: request.requester_actor_id.clone(),
            requester_device_id: request.requester_device_id.clone(),
            result: Some(rpc_response::Result::RemoveWorkspaceResult(RemoveWorkspaceResult {
                accepted,
                error,
            })),
        }
    }
}

fn command_rejected_event(
    device_id: &str,
    command_id: String,
    reason: String,
) -> amux::DeviceCollabEvent {
    amux::DeviceCollabEvent {
        device_id: device_id.to_string(),
        timestamp: chrono::Utc::now().timestamp(),
        event: Some(amux::device_collab_event::Event::CommandRejected(
            amux::PromptRejected { command_id, reason },
        )),
    }
}

fn agent_start_result_event(
    device_id: &str,
    command_id: String,
    success: bool,
    error: String,
    agent_id: String,
    session_id: String,
) -> amux::DeviceCollabEvent {
    amux::DeviceCollabEvent {
        device_id: device_id.to_string(),
        timestamp: chrono::Utc::now().timestamp(),
        event: Some(amux::device_collab_event::Event::AgentStartResult(
            amux::LegacyAgentStartResult {
                command_id,
                success,
                error,
                runtime_id: agent_id,
                session_id,
            },
        )),
    }
}

/// Shrinks an `AcpAvailableCommands` list in place so the serialized message
/// stays under the broker's per-packet cap. Strategy: walk the description
/// length down (80 → 40 → 20 → 0) until the encoded size fits; if stripping
/// descriptions is still not enough, drop commands from the tail.
///
/// The budget is deliberately well under the 10 240-byte broker limit to
/// leave headroom for the envelope wrapper (device_id, agent_id, sequence,
/// etc.) and the MQTT topic name / fixed header.
fn fit_available_commands_in_budget(ac: &mut crate::proto::amux::AcpAvailableCommands) {
    use prost::Message;
    const BUDGET: usize = 8_500;

    if ac.encoded_len() <= BUDGET {
        return;
    }

    for &limit in &[80usize, 40, 20, 0] {
        for cmd in &mut ac.commands {
            if cmd.description.chars().count() > limit {
                cmd.description = cmd.description.chars().take(limit).collect();
            }
        }
        if ac.encoded_len() <= BUDGET {
            return;
        }
    }

    while ac.encoded_len() > BUDGET && !ac.commands.is_empty() {
        ac.commands.pop();
    }
}

fn format_task_prompt(session_id: &str, event: &crate::proto::teamclaw::TaskEvent) -> String {
    use crate::proto::teamclaw::task_event::Event;
    match &event.event {
        Some(Event::Created(item)) => format!("[Collab session: {}] New task: {} - {}", session_id, item.title, item.description),
        Some(Event::Updated(item)) => format!("[Collab session: {}] Task updated: {}", session_id, item.title),
        Some(Event::Claimed(claim)) => format!("[Collab session: {}] Task {} claimed by {}", session_id, claim.task_id, claim.actor_id),
        Some(Event::Submitted(sub)) => format!("[Collab session: {}] Submission for {}: {}", session_id, sub.task_id, sub.content),
        None => String::new(),
    }
}

fn not_yet_implemented(
    request: &crate::proto::teamclaw::RpcRequest,
    method_name: &str,
) -> crate::proto::teamclaw::RpcResponse {
    crate::proto::teamclaw::RpcResponse {
        request_id: request.request_id.clone(),
        success: false,
        error: format!("{} not yet implemented", method_name),
        requester_client_id: request.requester_client_id.clone(),
        requester_actor_id: request.requester_actor_id.clone(),
        requester_device_id: request.requester_device_id.clone(),
        result: None,
    }
}

#[cfg(test)]
mod tests {
    use super::{agent_start_result_event, command_rejected_event};
    use crate::proto::amux;

    #[test]
    fn command_rejected_event_carries_command_id_and_reason() {
        let event = command_rejected_event(
            "device-1",
            "cmd-123".to_string(),
            "Failed to start agent".to_string(),
        );

        assert_eq!(event.device_id, "device-1");
        match event.event {
            Some(amux::device_collab_event::Event::CommandRejected(rejected)) => {
                assert_eq!(rejected.command_id, "cmd-123");
                assert_eq!(rejected.reason, "Failed to start agent");
            }
            other => panic!("expected command_rejected event, got {:?}", other),
        }
    }

    #[test]
    fn agent_start_result_event_carries_correlation_and_payload() {
        let event = agent_start_result_event(
            "ios-device-1",
            "cmd-456".to_string(),
            true,
            String::new(),
            "agent-1".to_string(),
            "sess-1".to_string(),
        );

        assert_eq!(event.device_id, "ios-device-1");
        match event.event {
            Some(amux::device_collab_event::Event::AgentStartResult(result)) => {
                assert_eq!(result.command_id, "cmd-456");
                assert!(result.success);
                assert_eq!(result.runtime_id, "agent-1");
                assert_eq!(result.session_id, "sess-1");
                assert!(result.error.is_empty());
            }
            other => panic!("expected agent_start_result event, got {:?}", other),
        }
    }
}
