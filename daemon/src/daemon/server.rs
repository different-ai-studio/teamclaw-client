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

/// Outcome of apply_start_runtime. Success path returns the allocated
/// runtime_id + the session_id (echoed from request or freshly created).
/// Failure path returns a (error_code, error_message, failed_stage) tuple
/// — the caller formats this into whatever wire envelope it emits
/// (legacy AgentStartResult or new RuntimeStartResult).
struct StartRuntimeOutcome {
    runtime_id: String,
    session_id: String,
}

struct StartRuntimeError {
    error_code: String,
    error_message: String,
    failed_stage: String,
}

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
            Some(Method::RemoveMember(r)) => self.handle_remove_member(&request, r).await,
            Some(Method::RuntimeStop(s)) => self.handle_stop_runtime(&request, s).await,
            Some(Method::RuntimeStart(s)) => self.handle_start_runtime(&request, s).await,
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
                // Phase 2b: device/{id}/notify carries two wire shapes during the
                // compat window — new Teamclaw_Notify (event_type + refresh_hint)
                // and legacy NotifyEnvelope (pre-Phase-2b daemons still emit it).
                // Field numbers are wire-incompatible: try Notify first (smaller
                // schema, safer false-positive on short payloads), fall back to
                // NotifyEnvelope for old-format messages.
                let parsed: Option<(String, String)> = if let Ok(n) =
                    crate::proto::teamclaw::Notify::decode(payload.as_slice())
                {
                    Some((n.event_type, n.refresh_hint))
                } else if let Ok(env) =
                    crate::proto::teamclaw::NotifyEnvelope::decode(payload.as_slice())
                {
                    Some((env.event_type, env.session_id))
                } else {
                    warn!("failed to decode device/notify payload as Notify or NotifyEnvelope");
                    None
                };

                if let Some((event_type, refresh_hint)) = parsed {
                    if event_type == "membership.refresh" && !refresh_hint.is_empty() {
                        if let Some(tc) = &mut self.teamclaw {
                            if let Err(err) = tc.refresh_membership_subscriptions().await {
                                warn!(?err, session_id = %refresh_hint, "failed to refresh membership subscriptions after notify");
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
            warn!(
                peer_id,
                reply_device_id = %reply_device_id,
                command_id = %command_id,
                %reason,
                "command rejected; legacy collab NACK no longer published"
            );
            return;
        }

        match cmd {
            amux::acp_command::Command::StartAgent(start) => {
                let at = amux::AgentType::try_from(start.agent_type)
                    .unwrap_or(amux::AgentType::ClaudeCode);

                info!(
                    workspace_id = %start.workspace_id,
                    worktree = %start.worktree,
                    peer_id,
                    "received startAgent envelope"
                );

                let outcome = self
                    .apply_start_runtime(
                        at,
                        &start.workspace_id,
                        &start.worktree,
                        &start.session_id,
                        &start.initial_prompt,
                    )
                    .await;

                match outcome {
                    Ok(res) => {
                        info!(
                            agent_id = %res.runtime_id,
                            peer_id,
                            reply_device_id = %reply_device_id,
                            command_id = %command_id,
                            session_id = %res.session_id,
                            "agent started; legacy collab AgentStartResult no longer published"
                        );
                    }
                    Err(err) => {
                        let reason = err.error_message.clone();
                        error!(
                            peer_id,
                            reply_device_id = %reply_device_id,
                            command_id = %command_id,
                            session_id = %start.session_id,
                            "startAgent failed: {}; legacy collab AgentStartResult no longer published",
                            reason
                        );
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

    /// Applies a member removal. Returns (success, error_text).
    /// Caller passes `requester_is_owner` because the two callers have
    /// different ways to establish it: legacy collab path looks up the
    /// peer's role via PeerTracker; RPC path looks up the requester_actor_id
    /// through AuthManager::is_owner.
    async fn apply_remove_member(
        &mut self,
        remove: &amux::RemoveMember,
        requester_is_owner: bool,
    ) -> (bool, String) {
        if !requester_is_owner {
            warn!(member_id = %remove.member_id, "remove rejected: not owner");
            return (false, "not owner".to_string());
        }
        match self.auth.remove_member(&remove.member_id) {
            Ok(true) => {
                let kicked = self.peers.remove_by_member_id(&remove.member_id);
                for p in &kicked {
                    info!(peer_id = %p.peer_id, "peer kicked");
                }
                (true, String::new())
            }
            Ok(false) => (false, format!("member not found: {}", remove.member_id)),
            Err(e) => (false, e.to_string()),
        }
    }

    async fn handle_remove_member(
        &mut self,
        request: &crate::proto::teamclaw::RpcRequest,
        remove: &crate::proto::teamclaw::RemoveMemberRequest,
    ) -> crate::proto::teamclaw::RpcResponse {
        use crate::proto::teamclaw::{rpc_response, RemoveMemberResult, RpcResponse};

        let amux_remove = amux::RemoveMember { member_id: remove.member_id.clone() };
        // RPC carries requester identity in payload; resolve is_owner via
        // AuthManager, which is the source of truth for member roles.
        let is_owner = self.auth.is_owner(&request.requester_actor_id);
        let (accepted, error) = self.apply_remove_member(&amux_remove, is_owner).await;

        if accepted {
            let publisher = Publisher::new(&self.mqtt);
            let _ = publisher.publish_notify("members.changed", "").await;
        }

        RpcResponse {
            request_id: request.request_id.clone(),
            success: accepted,
            error: error.clone(),
            requester_client_id: request.requester_client_id.clone(),
            requester_actor_id: request.requester_actor_id.clone(),
            requester_device_id: request.requester_device_id.clone(),
            result: Some(rpc_response::Result::RemoveMemberResult(RemoveMemberResult {
                accepted,
                error,
            })),
        }
    }

    /// Spawns a Claude Code subprocess and publishes lifecycle state
    /// transitions on the retained runtime state topic. Shared by legacy
    /// AcpCommand::StartAgent and RPC RuntimeStart handlers.
    ///
    /// Lifecycle publishes:
    ///   - STARTING (stage "spawning_process") published retained right after
    ///     spawn_agent returns the new runtime_id, before StoredSession upsert.
    ///   - ACTIVE published retained via publish_agent_state_by_id after
    ///     StoredSession upsert (that call reads the now-populated AgentHandle).
    ///   - No FAILED publish here — spawn_agent error path returns before any
    ///     runtime_id is allocated, so there is no retained topic to write to.
    ///     Callers may surface the error via their wire envelope.
    async fn apply_start_runtime(
        &mut self,
        agent_type: amux::AgentType,
        workspace_id: &str,
        worktree: &str,
        session_id: &str,
        initial_prompt: &str,
    ) -> Result<StartRuntimeOutcome, StartRuntimeError> {
        info!(
            workspace_id,
            worktree,
            session_id,
            "apply_start_runtime"
        );

        // Resolve workspace + worktree. Same 4-branch logic as the legacy
        // AcpCommand::StartAgent arm (see server.rs ~800-836 pre-refactor).
        let (resolved_worktree, ws_id, supabase_ws_id_owned): (String, String, Option<String>) =
            if !workspace_id.is_empty() {
                if let Some(ws) = self.workspaces.find_by_id(workspace_id) {
                    (
                        ws.path.clone(),
                        ws.workspace_id.clone(),
                        (!ws.supabase_workspace_id.is_empty())
                            .then_some(ws.supabase_workspace_id.clone()),
                    )
                } else if !worktree.is_empty() {
                    (
                        worktree.to_string(),
                        String::new(),
                        Some(workspace_id.to_string()),
                    )
                } else {
                    return Err(StartRuntimeError {
                        error_code: "WORKSPACE_NOT_FOUND".to_string(),
                        error_message: format!(
                            "workspace {} not found and no worktree path provided",
                            workspace_id
                        ),
                        failed_stage: "validation".to_string(),
                    });
                }
            } else {
                // Bare-agent spawn: empty workspace_id. Use worktree if
                // provided, else "." (today's legacy default).
                let wt = if worktree.is_empty() {
                    ".".to_string()
                } else {
                    worktree.to_string()
                };
                (wt, String::new(), None)
            };
        let supabase_ws_id = supabase_ws_id_owned.as_deref();
        let session_id_opt = (!session_id.is_empty()).then_some(session_id);

        // Spawn.
        let new_id = match self
            .agents
            .spawn_agent(
                agent_type,
                &resolved_worktree,
                initial_prompt,
                &ws_id,
                supabase_ws_id,
                session_id_opt,
            )
            .await
        {
            Ok(id) => id,
            Err(e) => {
                error!("spawn_agent failed: {}", e);
                // We never allocated a retained topic (spawn_agent failed before
                // returning an id), so there's no retain to publish FAILED to.
                // The caller formats the error into its wire envelope; no state
                // topic is involved.
                return Err(StartRuntimeError {
                    error_code: "SPAWN_FAILED".to_string(),
                    error_message: format!("spawn_agent failed: {}", e),
                    failed_stage: "spawning_process".to_string(),
                });
            }
        };

        // STARTING retain — fleeting but observable by mid-spawn reconnects.
        let publisher = Publisher::new(&self.mqtt);
        let starting_info = amux::RuntimeInfo {
            runtime_id: new_id.clone(),
            agent_type: agent_type as i32,
            worktree: resolved_worktree.clone(),
            workspace_id: ws_id.clone(),
            state: amux::RuntimeLifecycle::Starting as i32,
            stage: "spawning_process".to_string(),
            started_at: chrono::Utc::now().timestamp(),
            ..Default::default()
        };
        let _ = publisher.publish_agent_state(&new_id, &starting_info).await;

        // Persist session + transition to ACTIVE.
        let acp_sid = self
            .agents
            .get_handle(&new_id)
            .map(|h| h.acp_session_id.clone())
            .unwrap_or_default();
        let stored = StoredSession {
            session_id: new_id.clone(),
            acp_session_id: acp_sid,
            collab_session_id: session_id.to_string(),
            agent_type: agent_type as i32,
            workspace_id: ws_id,
            worktree: resolved_worktree,
            status: amux::AgentStatus::Active as i32,
            created_at: chrono::Utc::now().timestamp(),
            last_prompt: initial_prompt.to_string(),
            last_output_summary: String::new(),
            tool_use_count: 0,
        };
        self.sessions.upsert(stored);
        let _ = self.sessions.save(&self.sessions_path);

        // ACTIVE — publish_agent_state_by_id reads the live AgentHandle and
        // dual-publishes to agent/{id}/state + runtime/{id}/state. The handle
        // today encodes state=ACTIVE (Phase 1a Task 4).
        self.publish_agent_state_by_id(&new_id).await;

        Ok(StartRuntimeOutcome {
            runtime_id: new_id,
            session_id: session_id.to_string(),
        })
    }

    async fn handle_stop_runtime(
        &mut self,
        request: &crate::proto::teamclaw::RpcRequest,
        stop: &crate::proto::teamclaw::RuntimeStopRequest,
    ) -> crate::proto::teamclaw::RpcResponse {
        use crate::proto::teamclaw::{rpc_response, RpcResponse, RuntimeStopResult};

        let runtime_id = stop.runtime_id.clone();
        if runtime_id.is_empty() {
            return reject_stop(request, "runtime_id required");
        }

        // Reject if runtime is not known.
        if self.agents.get_handle(&runtime_id).is_none() {
            return reject_stop(request, &format!("unknown runtime_id: {}", runtime_id));
        }

        // Terminate via AgentManager (same path as AcpCommand::StopAgent).
        if self.agents.stop_agent(&runtime_id).await.is_none() {
            return reject_stop(request, &format!("stop failed for runtime_id: {}", runtime_id));
        }

        // Update session store to reflect stopped status (mirrors StopAgent side-effect).
        if let Some(session) = self.sessions.find_by_id_mut(&runtime_id) {
            session.status = amux::AgentStatus::Stopped as i32;
            let _ = self.sessions.save(&self.sessions_path);
        }

        // Publish terminal RuntimeInfo to both retained state topics, then clear.
        let stopped_info = amux::RuntimeInfo {
            runtime_id: runtime_id.clone(),
            state: amux::RuntimeLifecycle::Stopped as i32,
            ..Default::default()
        };
        let publisher = Publisher::new(&self.mqtt);
        let _ = publisher.publish_agent_state(&runtime_id, &stopped_info).await;
        let _ = publisher.clear_agent_state(&runtime_id).await;

        RpcResponse {
            request_id: request.request_id.clone(),
            success: true,
            error: String::new(),
            requester_client_id: request.requester_client_id.clone(),
            requester_actor_id: request.requester_actor_id.clone(),
            requester_device_id: request.requester_device_id.clone(),
            result: Some(rpc_response::Result::RuntimeStopResult(RuntimeStopResult {
                accepted: true,
                rejected_reason: String::new(),
            })),
        }
    }

    async fn handle_start_runtime(
        &mut self,
        request: &crate::proto::teamclaw::RpcRequest,
        start: &crate::proto::teamclaw::RuntimeStartRequest,
    ) -> crate::proto::teamclaw::RpcResponse {
        use crate::proto::teamclaw::{rpc_response, RpcResponse, RuntimeStartResult};

        let at = amux::AgentType::try_from(start.agent_type)
            .unwrap_or(amux::AgentType::ClaudeCode);

        // Note: start.model_id is accepted for wire compatibility but not yet
        // threaded through apply_start_runtime — the legacy AcpStartAgent path
        // doesn't carry it either. Future work (Phase 1c+).

        let outcome = self
            .apply_start_runtime(
                at,
                &start.workspace_id,
                &start.worktree,
                &start.session_id,
                &start.initial_prompt,
            )
            .await;

        match outcome {
            Ok(res) => RpcResponse {
                request_id: request.request_id.clone(),
                success: true,
                error: String::new(),
                requester_client_id: request.requester_client_id.clone(),
                requester_actor_id: request.requester_actor_id.clone(),
                requester_device_id: request.requester_device_id.clone(),
                result: Some(rpc_response::Result::RuntimeStartResult(RuntimeStartResult {
                    accepted: true,
                    runtime_id: res.runtime_id,
                    session_id: res.session_id,
                    rejected_reason: String::new(),
                })),
            },
            Err(err) => RpcResponse {
                request_id: request.request_id.clone(),
                success: false,
                error: err.error_message.clone(),
                requester_client_id: request.requester_client_id.clone(),
                requester_actor_id: request.requester_actor_id.clone(),
                requester_device_id: request.requester_device_id.clone(),
                result: Some(rpc_response::Result::RuntimeStartResult(RuntimeStartResult {
                    accepted: false,
                    runtime_id: String::new(),
                    session_id: String::new(),
                    rejected_reason: err.error_message,
                })),
            },
        }
    }
}

fn reject_stop(
    request: &crate::proto::teamclaw::RpcRequest,
    reason: &str,
) -> crate::proto::teamclaw::RpcResponse {
    use crate::proto::teamclaw::{rpc_response, RpcResponse, RuntimeStopResult};
    RpcResponse {
        request_id: request.request_id.clone(),
        success: false,
        error: reason.to_string(),
        requester_client_id: request.requester_client_id.clone(),
        requester_actor_id: request.requester_actor_id.clone(),
        requester_device_id: request.requester_device_id.clone(),
        result: Some(rpc_response::Result::RuntimeStopResult(RuntimeStopResult {
            accepted: false,
            rejected_reason: reason.to_string(),
        })),
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

