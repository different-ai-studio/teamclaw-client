use crate::proto::teamclaw::{self, RpcRequest, RpcResponse};
use crate::teamclaw::{
    MessageStore, RpcServer, StoredClaim, StoredCollabSession, StoredMessage, StoredParticipant,
    StoredSubmission, StoredWorkItem, TeamclawSessionStore, TeamclawTopics, WorkItemStore,
};
use chrono::Utc;
use rumqttc::{AsyncClient, QoS};
use std::path::PathBuf;
use tracing::{info, warn};
use uuid::Uuid;

pub struct SessionManager {
    topics: TeamclawTopics,
    client: AsyncClient,
    rpc_server: RpcServer,
    pub(crate) sessions: TeamclawSessionStore,
    sessions_path: PathBuf,
    pub(crate) config_dir: PathBuf,
    device_id: String,
    team_id: String,
    is_team_host: bool,
    team_host_device_id: Option<String>,
}

impl SessionManager {
    pub fn new(
        client: AsyncClient,
        team_id: &str,
        device_id: &str,
        config_dir: PathBuf,
        is_team_host: bool,
        team_host_device_id: Option<String>,
    ) -> crate::error::Result<Self> {
        let topics = TeamclawTopics::new(team_id, device_id);
        let rpc_server = RpcServer::new(client.clone(), team_id.to_string(), device_id.to_string());
        let sessions_path = TeamclawSessionStore::default_path(&config_dir);
        let sessions = TeamclawSessionStore::load(&sessions_path)?;

        Ok(Self {
            topics,
            client,
            rpc_server,
            sessions,
            sessions_path,
            config_dir,
            device_id: device_id.to_string(),
            team_id: team_id.to_string(),
            is_team_host,
            team_host_device_id,
        })
    }

    /// Subscribe to all relevant teamclaw topics.
    pub async fn subscribe_all(&self) -> crate::error::Result<()> {
        // Team-level topics
        self.client
            .subscribe(self.topics.members(), QoS::AtLeastOnce)
            .await?;
        self.client
            .subscribe(self.topics.sessions(), QoS::AtLeastOnce)
            .await?;

        // Global work items topic
        self.client
            .subscribe(self.topics.workitems(), QoS::AtLeastOnce)
            .await?;

        // RPC: incoming requests for this device
        self.client
            .subscribe(self.topics.rpc_incoming_requests(), QoS::AtLeastOnce)
            .await?;

        // RPC: responses directed at this device
        let rpc_responses = format!(
            "teamclaw/{}/rpc/{}/+/res",
            self.team_id, self.device_id
        );
        self.client
            .subscribe(rpc_responses, QoS::AtLeastOnce)
            .await?;

        // Subscribe to all known sessions
        let session_ids: Vec<String> = self
            .sessions
            .sessions
            .iter()
            .map(|s| s.session_id.clone())
            .collect();
        for session_id in &session_ids {
            self.subscribe_session(session_id).await?;
        }

        Ok(())
    }

    /// Handle an incoming RPC request on topic with the given payload.
    ///
    /// `host_primary_agent_id` is the agent_id this device should record as
    /// the new session's primary agent if a CreateSession RPC arrives. The
    /// caller (DaemonServer) computes this from `AgentManager` so that the
    /// SessionManager doesn't need a back-reference into agent state.
    pub async fn handle_rpc_request(
        &mut self,
        topic: &str,
        payload: &[u8],
        host_primary_agent_id: Option<String>,
    ) {
        let (request_id, req) = match RpcServer::parse_request(topic, payload) {
            Some(pair) => pair,
            None => {
                warn!("SessionManager: failed to parse RPC request from topic: {}", topic);
                return;
            }
        };

        let response = match &req.method {
            Some(teamclaw::rpc_request::Method::CreateSession(r)) => {
                let r = r.clone();
                self.handle_create_session(&req, r, host_primary_agent_id.clone()).await
            }
            Some(teamclaw::rpc_request::Method::FetchSession(r)) => {
                let r = r.clone();
                self.handle_fetch_session(&req, r).await
            }
            Some(teamclaw::rpc_request::Method::JoinSession(r)) => {
                let r = r.clone();
                self.handle_join_session(&req, r).await
            }
            Some(teamclaw::rpc_request::Method::AddParticipant(r)) => {
                let r = r.clone();
                self.handle_add_participant(&req, r).await
            }
            Some(teamclaw::rpc_request::Method::RemoveParticipant(r)) => {
                let r = r.clone();
                self.handle_remove_participant(&req, r).await
            }
            Some(teamclaw::rpc_request::Method::CreateWorkItem(r)) => {
                let r = r.clone();
                self.handle_create_work_item(&req, r).await
            }
            Some(teamclaw::rpc_request::Method::ClaimWorkItem(r)) => {
                let r = r.clone();
                self.handle_claim_work_item(&req, r).await
            }
            Some(teamclaw::rpc_request::Method::SubmitWorkItem(r)) => {
                let r = r.clone();
                self.handle_submit_work_item(&req, r).await
            }
            Some(teamclaw::rpc_request::Method::UpdateWorkItem(r)) => {
                let r = r.clone();
                self.handle_update_work_item(&req, r).await
            }
            Some(teamclaw::rpc_request::Method::RegisterSession(r)) => {
                let r = r.clone();
                self.handle_register_session(&req, r).await
            }
            None => {
                warn!("SessionManager: received RPC request with no method");
                RpcResponse {
                    request_id: request_id.clone(),
                    success: false,
                    error: "no method specified".to_string(),
                    result: None,
                }
            }
        };

        self.rpc_server.respond(&req, &request_id, response).await;
    }

    // --- RPC Handlers ---

    async fn handle_create_session(
        &mut self,
        req: &RpcRequest,
        r: teamclaw::CreateSessionRequest,
        host_primary_agent_id: Option<String>,
    ) -> RpcResponse {
        let session_id = Uuid::new_v4().to_string();
        let session_type = match r.session_type {
            x if x == teamclaw::SessionType::Control as i32 => "control",
            _ => "collab",
        };

        let session = StoredCollabSession {
            session_id: session_id.clone(),
            session_type: session_type.to_string(),
            team_id: r.team_id.clone(),
            title: r.title.clone(),
            host_device_id: self.device_id.clone(),
            created_by: req.sender_device_id.clone(),
            created_at: Utc::now(),
            summary: r.summary.clone(),
            participants: vec![],
            primary_agent_id: host_primary_agent_id.unwrap_or_default(),
        };

        self.sessions.upsert(session);
        if let Err(e) = self.sessions.save(&self.sessions_path) {
            warn!("handle_create_session: failed to save sessions: {}", e);
        }

        // Publish session meta (retained)
        if let Err(e) = self.publish_session_meta(&session_id).await {
            warn!("handle_create_session: failed to publish session meta: {}", e);
        }

        // Subscribe to session topics
        if let Err(e) = self.subscribe_session(&session_id).await {
            warn!("handle_create_session: failed to subscribe to session: {}", e);
        }

        // Send invites to invited actors
        for actor_id in &r.invite_actor_ids {
            let invite = teamclaw::Invite {
                invite_id: Uuid::new_v4().to_string(),
                session_id: session_id.clone(),
                team_id: r.team_id.clone(),
                host_device_id: self.device_id.clone(),
                invited_by: req.sender_device_id.clone(),
                invited_actor_id: actor_id.clone(),
                session_title: r.title.clone(),
                summary: r.summary.clone(),
                created_at: Utc::now().timestamp(),
            };
            let envelope = teamclaw::InviteEnvelope { invite: Some(invite) };
            let topic = self.topics.user_invites(actor_id);
            let payload = envelope.encode_to_vec();
            if let Err(e) = self
                .client
                .publish(topic, QoS::AtLeastOnce, false, payload)
                .await
            {
                warn!("handle_create_session: failed to publish invite for {}: {}", actor_id, e);
            }
        }

        // If team host, update session index
        if self.is_team_host {
            if let Err(e) = self.publish_session_index().await {
                warn!("handle_create_session: failed to publish session index: {}", e);
            }
        } else if let Some(host_id) = &self.team_host_device_id {
            // Send RegisterSessionRequest RPC to team host
            let entry = teamclaw::SessionIndexEntry {
                session_id: session_id.clone(),
                session_type: r.session_type,
                title: r.title.clone(),
                host_device_id: self.device_id.clone(),
                created_at: Utc::now().timestamp(),
                participant_count: 0,
                ..Default::default()
            };
            let rpc_req = RpcRequest {
                request_id: Uuid::new_v4().to_string()[..8].to_string(),
                sender_device_id: self.device_id.clone(),
                method: Some(teamclaw::rpc_request::Method::RegisterSession(
                    teamclaw::RegisterSessionRequest {
                        entry: Some(entry),
                    },
                )),
            };
            let topic = self.topics.rpc_request(host_id, &rpc_req.request_id);
            let _ = self.client.publish(topic, QoS::AtLeastOnce, false, rpc_req.encode_to_vec()).await;
            info!(session_id = %session_id, team_host = %host_id, "sent RegisterSession RPC to team host");
        } else {
            warn!(session_id = %session_id, "non-team-host with no team_host_device_id configured, session index not updated");
        }

        let session_info = self.sessions.to_proto_session_info(&session_id);
        info!(session_id = %session_id, "session created");

        RpcResponse {
            request_id: req.request_id.clone(),
            success: true,
            error: String::new(),
            result: session_info.map(|s| teamclaw::rpc_response::Result::SessionInfo(s)),
        }
    }

    async fn handle_fetch_session(
        &self,
        req: &RpcRequest,
        r: teamclaw::FetchSessionRequest,
    ) -> RpcResponse {
        match self.sessions.to_proto_session_info(&r.session_id) {
            Some(info) => RpcResponse {
                request_id: req.request_id.clone(),
                success: true,
                error: String::new(),
                result: Some(teamclaw::rpc_response::Result::SessionInfo(info)),
            },
            None => RpcResponse {
                request_id: req.request_id.clone(),
                success: false,
                error: format!("session {} not found", r.session_id),
                result: None,
            },
        }
    }

    async fn handle_join_session(
        &mut self,
        req: &RpcRequest,
        r: teamclaw::JoinSessionRequest,
    ) -> RpcResponse {
        let participant = match r.participant {
            Some(p) => p,
            None => {
                return RpcResponse {
                    request_id: req.request_id.clone(),
                    success: false,
                    error: "missing participant".to_string(),
                    result: None,
                };
            }
        };

        let actor_type = actor_type_to_string(participant.actor_type);
        let stored_participant = StoredParticipant {
            actor_id: participant.actor_id.clone(),
            actor_type,
            display_name: participant.display_name.clone(),
            joined_at: Utc::now(),
        };

        match self.sessions.find_by_id_mut(&r.session_id) {
            Some(session) => {
                // Only add if not already a participant
                if !session
                    .participants
                    .iter()
                    .any(|p| p.actor_id == participant.actor_id)
                {
                    session.participants.push(stored_participant);
                }
            }
            None => {
                return RpcResponse {
                    request_id: req.request_id.clone(),
                    success: false,
                    error: format!("session {} not found", r.session_id),
                    result: None,
                };
            }
        }

        if let Err(e) = self.sessions.save(&self.sessions_path) {
            warn!("handle_join_session: failed to save sessions: {}", e);
        }
        if let Err(e) = self.publish_session_meta(&r.session_id).await {
            warn!("handle_join_session: failed to publish session meta: {}", e);
        }

        let session_info = self.sessions.to_proto_session_info(&r.session_id);
        info!(session_id = %r.session_id, actor_id = %participant.actor_id, "participant joined session");

        RpcResponse {
            request_id: req.request_id.clone(),
            success: true,
            error: String::new(),
            result: session_info.map(|s| teamclaw::rpc_response::Result::SessionInfo(s)),
        }
    }

    async fn handle_add_participant(
        &mut self,
        req: &RpcRequest,
        r: teamclaw::AddParticipantRequest,
    ) -> RpcResponse {
        let participant = match r.participant {
            Some(p) => p,
            None => {
                return RpcResponse {
                    request_id: req.request_id.clone(),
                    success: false,
                    error: "missing participant".to_string(),
                    result: None,
                };
            }
        };

        let actor_type = actor_type_to_string(participant.actor_type);
        let stored_participant = StoredParticipant {
            actor_id: participant.actor_id.clone(),
            actor_type,
            display_name: participant.display_name.clone(),
            joined_at: Utc::now(),
        };

        match self.sessions.find_by_id_mut(&r.session_id) {
            Some(session) => {
                if !session
                    .participants
                    .iter()
                    .any(|p| p.actor_id == participant.actor_id)
                {
                    session.participants.push(stored_participant);
                }
            }
            None => {
                return RpcResponse {
                    request_id: req.request_id.clone(),
                    success: false,
                    error: format!("session {} not found", r.session_id),
                    result: None,
                };
            }
        }

        if let Err(e) = self.sessions.save(&self.sessions_path) {
            warn!("handle_add_participant: failed to save sessions: {}", e);
        }
        if let Err(e) = self.publish_session_meta(&r.session_id).await {
            warn!("handle_add_participant: failed to publish session meta: {}", e);
        }

        let session_info = self.sessions.to_proto_session_info(&r.session_id);
        info!(session_id = %r.session_id, actor_id = %participant.actor_id, "participant added to session");

        RpcResponse {
            request_id: req.request_id.clone(),
            success: true,
            error: String::new(),
            result: session_info.map(|s| teamclaw::rpc_response::Result::SessionInfo(s)),
        }
    }

    async fn handle_remove_participant(
        &mut self,
        req: &RpcRequest,
        r: teamclaw::RemoveParticipantRequest,
    ) -> RpcResponse {
        match self.sessions.find_by_id_mut(&r.session_id) {
            Some(session) => {
                session.participants.retain(|p| p.actor_id != r.actor_id);
            }
            None => {
                return RpcResponse {
                    request_id: req.request_id.clone(),
                    success: false,
                    error: format!("session {} not found", r.session_id),
                    result: None,
                };
            }
        }

        if let Err(e) = self.sessions.save(&self.sessions_path) {
            warn!("handle_remove_participant: failed to save sessions: {}", e);
        }
        if let Err(e) = self.publish_session_meta(&r.session_id).await {
            warn!("handle_remove_participant: failed to publish session meta: {}", e);
        }

        let session_info = self.sessions.to_proto_session_info(&r.session_id);
        info!(session_id = %r.session_id, actor_id = %r.actor_id, "participant removed from session");

        RpcResponse {
            request_id: req.request_id.clone(),
            success: true,
            error: String::new(),
            result: session_info.map(|s| teamclaw::rpc_response::Result::SessionInfo(s)),
        }
    }

    async fn handle_create_work_item(
        &mut self,
        req: &RpcRequest,
        r: teamclaw::CreateWorkItemRequest,
    ) -> RpcResponse {
        let work_item_id = Uuid::new_v4().to_string();
        let stored_item = StoredWorkItem {
            work_item_id: work_item_id.clone(),
            session_id: r.session_id.clone(),
            title: r.title.clone(),
            description: r.description.clone(),
            status: "open".to_string(),
            parent_id: r.parent_id.clone(),
            created_by: req.sender_device_id.clone(),
            created_at: Utc::now(),
        };

        let store_key = if r.session_id.is_empty() { "global" } else { &r.session_id };

        let mut store = match WorkItemStore::load(&self.config_dir, store_key) {
            Ok(s) => s,
            Err(e) => {
                warn!("handle_create_work_item: failed to load work item store: {}", e);
                return RpcResponse {
                    request_id: req.request_id.clone(),
                    success: false,
                    error: e.to_string(),
                    result: None,
                };
            }
        };

        store.add_item(stored_item);

        if let Err(e) = store.save(&self.config_dir, store_key) {
            warn!("handle_create_work_item: failed to save work item store: {}", e);
        }

        let work_item = store
            .find_item(&work_item_id)
            .map(|i| store.to_proto_work_item(i));

        // Publish WorkItemEvent
        if let Some(ref item) = work_item {
            let event = teamclaw::WorkItemEvent {
                event: Some(teamclaw::work_item_event::Event::Created(item.clone())),
            };
            let topic = if r.session_id.is_empty() {
                self.topics.workitems()
            } else {
                self.topics.session_workitems(&r.session_id)
            };
            let payload = event.encode_to_vec();
            if let Err(e) = self
                .client
                .publish(topic, QoS::AtLeastOnce, false, payload)
                .await
            {
                warn!("handle_create_work_item: failed to publish work item event: {}", e);
            }
        }

        info!(work_item_id = %work_item_id, session_id = %r.session_id, "work item created");

        RpcResponse {
            request_id: req.request_id.clone(),
            success: true,
            error: String::new(),
            result: work_item.map(|wi| teamclaw::rpc_response::Result::WorkItem(wi)),
        }
    }

    async fn handle_claim_work_item(
        &mut self,
        req: &RpcRequest,
        r: teamclaw::ClaimWorkItemRequest,
    ) -> RpcResponse {
        let mut store = match WorkItemStore::load(&self.config_dir, &r.session_id) {
            Ok(s) => s,
            Err(e) => {
                return RpcResponse {
                    request_id: req.request_id.clone(),
                    success: false,
                    error: e.to_string(),
                    result: None,
                };
            }
        };

        let claim_id = Uuid::new_v4().to_string();
        let claim = StoredClaim {
            claim_id: claim_id.clone(),
            work_item_id: r.work_item_id.clone(),
            actor_id: req.sender_device_id.clone(),
            claimed_at: Utc::now(),
        };

        store.add_claim(claim);

        if let Err(e) = store.save(&self.config_dir, &r.session_id) {
            warn!("handle_claim_work_item: failed to save work item store: {}", e);
        }

        let proto_claim = teamclaw::Claim {
            claim_id: claim_id.clone(),
            work_item_id: r.work_item_id.clone(),
            actor_id: req.sender_device_id.clone(),
            claimed_at: Utc::now().timestamp(),
        };

        // Publish WorkItemEvent
        let event = teamclaw::WorkItemEvent {
            event: Some(teamclaw::work_item_event::Event::Claimed(proto_claim.clone())),
        };
        let topic = self.topics.session_workitems(&r.session_id);
        let payload = event.encode_to_vec();
        if let Err(e) = self
            .client
            .publish(topic, QoS::AtLeastOnce, false, payload)
            .await
        {
            warn!("handle_claim_work_item: failed to publish claim event: {}", e);
        }

        info!(
            claim_id = %claim_id,
            work_item_id = %r.work_item_id,
            session_id = %r.session_id,
            "work item claimed"
        );

        RpcResponse {
            request_id: req.request_id.clone(),
            success: true,
            error: String::new(),
            result: Some(teamclaw::rpc_response::Result::Claim(proto_claim)),
        }
    }

    async fn handle_submit_work_item(
        &mut self,
        req: &RpcRequest,
        r: teamclaw::SubmitWorkItemRequest,
    ) -> RpcResponse {
        let mut store = match WorkItemStore::load(&self.config_dir, &r.session_id) {
            Ok(s) => s,
            Err(e) => {
                return RpcResponse {
                    request_id: req.request_id.clone(),
                    success: false,
                    error: e.to_string(),
                    result: None,
                };
            }
        };

        let submission_id = Uuid::new_v4().to_string();
        let submission = StoredSubmission {
            submission_id: submission_id.clone(),
            work_item_id: r.work_item_id.clone(),
            actor_id: req.sender_device_id.clone(),
            content: r.content.clone(),
            submitted_at: Utc::now(),
        };

        store.add_submission(submission);

        if let Err(e) = store.save(&self.config_dir, &r.session_id) {
            warn!("handle_submit_work_item: failed to save work item store: {}", e);
        }

        let proto_submission = teamclaw::Submission {
            submission_id: submission_id.clone(),
            work_item_id: r.work_item_id.clone(),
            actor_id: req.sender_device_id.clone(),
            content: r.content.clone(),
            submitted_at: Utc::now().timestamp(),
        };

        // Publish WorkItemEvent
        let event = teamclaw::WorkItemEvent {
            event: Some(teamclaw::work_item_event::Event::Submitted(
                proto_submission.clone(),
            )),
        };
        let topic = self.topics.session_workitems(&r.session_id);
        let payload = event.encode_to_vec();
        if let Err(e) = self
            .client
            .publish(topic, QoS::AtLeastOnce, false, payload)
            .await
        {
            warn!("handle_submit_work_item: failed to publish submission event: {}", e);
        }

        info!(
            submission_id = %submission_id,
            work_item_id = %r.work_item_id,
            session_id = %r.session_id,
            "work item submitted"
        );

        RpcResponse {
            request_id: req.request_id.clone(),
            success: true,
            error: String::new(),
            result: Some(teamclaw::rpc_response::Result::Submission(proto_submission)),
        }
    }

    async fn handle_update_work_item(
        &mut self,
        req: &RpcRequest,
        r: teamclaw::UpdateWorkItemRequest,
    ) -> RpcResponse {
        let mut store = match WorkItemStore::load(&self.config_dir, &r.session_id) {
            Ok(s) => s,
            Err(e) => {
                return RpcResponse {
                    request_id: req.request_id.clone(),
                    success: false,
                    error: e.to_string(),
                    result: None,
                };
            }
        };

        match store.find_item_mut(&r.work_item_id) {
            Some(item) => {
                if !r.title.is_empty() {
                    item.title = r.title.clone();
                }
                if !r.description.is_empty() {
                    item.description = r.description.clone();
                }
                // Update status if non-zero (unknown is 0)
                if r.status != 0 {
                    item.status = work_item_status_to_string(r.status);
                }
            }
            None => {
                return RpcResponse {
                    request_id: req.request_id.clone(),
                    success: false,
                    error: format!("work item {} not found", r.work_item_id),
                    result: None,
                };
            }
        }

        if let Err(e) = store.save(&self.config_dir, &r.session_id) {
            warn!("handle_update_work_item: failed to save work item store: {}", e);
        }

        let work_item = store
            .find_item(&r.work_item_id)
            .map(|i| store.to_proto_work_item(i));

        // Publish WorkItemEvent
        if let Some(ref item) = work_item {
            let event = teamclaw::WorkItemEvent {
                event: Some(teamclaw::work_item_event::Event::Updated(item.clone())),
            };
            let topic = self.topics.session_workitems(&r.session_id);
            let payload = event.encode_to_vec();
            if let Err(e) = self
                .client
                .publish(topic, QoS::AtLeastOnce, false, payload)
                .await
            {
                warn!("handle_update_work_item: failed to publish update event: {}", e);
            }
        }

        info!(
            work_item_id = %r.work_item_id,
            session_id = %r.session_id,
            "work item updated"
        );

        RpcResponse {
            request_id: req.request_id.clone(),
            success: true,
            error: String::new(),
            result: work_item.map(|wi| teamclaw::rpc_response::Result::WorkItem(wi)),
        }
    }

    async fn handle_register_session(
        &mut self,
        req: &RpcRequest,
        r: teamclaw::RegisterSessionRequest,
    ) -> RpcResponse {
        if !self.is_team_host {
            return RpcResponse {
                request_id: req.request_id.clone(),
                success: false,
                error: "this device is not the team host".to_string(),
                result: None,
            };
        }

        let entry = match r.entry {
            Some(e) => e,
            None => {
                return RpcResponse {
                    request_id: req.request_id.clone(),
                    success: false,
                    error: "missing session index entry".to_string(),
                    result: None,
                };
            }
        };

        // Check if session already in store; if not, add a stub entry
        if self.sessions.find_by_id(&entry.session_id).is_none() {
            let session_type = match entry.session_type {
                x if x == teamclaw::SessionType::Control as i32 => "control",
                _ => "collab",
            };
            let stored = StoredCollabSession {
                session_id: entry.session_id.clone(),
                session_type: session_type.to_string(),
                team_id: self.team_id.clone(),
                title: entry.title.clone(),
                host_device_id: entry.host_device_id.clone(),
                created_by: req.sender_device_id.clone(),
                created_at: Utc::now(),
                summary: String::new(),
                participants: vec![],
                // primary_agent_id is host-local state; the team host stores
                // a stub (empty) on RegisterSession and lets the host's own
                // SessionMeta publish carry the authoritative value.
                primary_agent_id: String::new(),
            };
            self.sessions.upsert(stored);
            if let Err(e) = self.sessions.save(&self.sessions_path) {
                warn!("handle_register_session: failed to save sessions: {}", e);
            }
        }

        if let Err(e) = self.publish_session_index().await {
            warn!("handle_register_session: failed to publish session index: {}", e);
        }

        info!(session_id = %entry.session_id, "session registered with team host");

        RpcResponse {
            request_id: req.request_id.clone(),
            success: true,
            error: String::new(),
            result: None,
        }
    }

    // --- Public helpers ---

    /// Persist an incoming message for a session.
    pub fn persist_message(
        &self,
        session_id: &str,
        message: &teamclaw::Message,
    ) -> crate::error::Result<()> {
        let stored = StoredMessage {
            message_id: message.message_id.clone(),
            session_id: message.session_id.clone(),
            sender_actor_id: message.sender_actor_id.clone(),
            kind: message_kind_to_string(message.kind),
            content: message.content.clone(),
            created_at: chrono::DateTime::from_timestamp(message.created_at, 0)
                .unwrap_or_else(Utc::now),
            reply_to_message_id: message.reply_to_message_id.clone(),
            mentions: message.mentions.clone(),
        };

        let mut store = MessageStore::load(&self.config_dir, session_id)?;
        store.append(stored);
        store.save(&self.config_dir, session_id)?;
        Ok(())
    }

    /// Returns true if this device is the host for the given session.
    pub fn is_host_for(&self, session_id: &str) -> bool {
        self.sessions
            .find_by_id(session_id)
            .map(|s| s.host_device_id == self.device_id)
            .unwrap_or(false)
    }

    /// Returns the agent actor_ids that should receive this message.
    ///
    /// If there's only one agent in the session, all messages are relevant.
    /// Otherwise, only agents that are explicitly mentioned.
    pub fn agents_to_activate(&self, session_id: &str, message: &teamclaw::Message) -> Vec<String> {
        let session = match self.sessions.find_by_id(session_id) {
            Some(s) => s,
            None => return vec![],
        };

        let agents: Vec<String> = session
            .participants
            .iter()
            .filter(|p| p.actor_type == "personal_agent" || p.actor_type == "role_agent")
            .map(|p| p.actor_id.clone())
            .collect();

        if agents.len() == 1 {
            // Only one agent — all messages activate it
            return agents;
        }

        // Multiple agents — only activate those mentioned
        agents
            .into_iter()
            .filter(|actor_id| message.mentions.contains(actor_id))
            .collect()
    }

    /// Returns the agent actor_ids that should be activated for a work item event.
    ///
    /// - Claimed → activate the claiming agent
    /// - Updated → activate all agents that claimed the work item
    /// - Submitted → activate other claimants (not the submitter)
    pub fn agents_to_activate_for_work_item(
        &self,
        session_id: &str,
        event: &teamclaw::WorkItemEvent,
    ) -> Vec<String> {
        match &event.event {
            Some(teamclaw::work_item_event::Event::Claimed(claim)) => {
                vec![claim.actor_id.clone()]
            }
            Some(teamclaw::work_item_event::Event::Updated(work_item)) => {
                // Activate all agents that claimed this work item
                match WorkItemStore::load(&self.config_dir, session_id) {
                    Ok(store) => store
                        .claims_for_item(&work_item.work_item_id)
                        .into_iter()
                        .map(|c| c.actor_id.clone())
                        .collect(),
                    Err(_) => vec![],
                }
            }
            Some(teamclaw::work_item_event::Event::Submitted(submission)) => {
                // Activate other claimants (not the submitter)
                match WorkItemStore::load(&self.config_dir, session_id) {
                    Ok(store) => store
                        .claims_for_item(&submission.work_item_id)
                        .into_iter()
                        .filter(|c| c.actor_id != submission.actor_id)
                        .map(|c| c.actor_id.clone())
                        .collect(),
                    Err(_) => vec![],
                }
            }
            Some(teamclaw::work_item_event::Event::Created(_)) | None => vec![],
        }
    }

    /// Get session_ids where this agent participates.
    pub fn sessions_for_agent(&self, agent_actor_id: &str) -> Vec<String> {
        self.sessions
            .sessions
            .iter()
            .filter(|s| s.participants.iter().any(|p| p.actor_id == agent_actor_id))
            .map(|s| s.session_id.clone())
            .collect()
    }

    /// Publish an agent's output as a session message.
    ///
    /// `model` is the model id the agent was running on when it produced this
    /// reply (looked up from `AgentManager.current_model` by the caller).
    /// Pass an empty string for legacy / unknown.
    pub async fn publish_agent_message(
        &self,
        session_id: &str,
        agent_actor_id: &str,
        content: &str,
        model: &str,
    ) {
        let msg = teamclaw::Message {
            message_id: Uuid::new_v4().to_string()[..8].to_string(),
            session_id: session_id.to_string(),
            sender_actor_id: agent_actor_id.to_string(),
            kind: teamclaw::MessageKind::Text as i32,
            content: content.to_string(),
            created_at: Utc::now().timestamp(),
            model: model.to_string(),
            ..Default::default()
        };
        let envelope = teamclaw::SessionMessageEnvelope {
            message: Some(msg),
        };
        let topic = self.topics.session_messages(session_id);
        let _ = self
            .client
            .publish(topic, QoS::AtLeastOnce, false, envelope.encode_to_vec())
            .await;
    }

    // --- Private helpers ---

    /// Publish the session's metadata as a retained message.
    async fn publish_session_meta(&self, session_id: &str) -> crate::error::Result<()> {
        let session_info = match self.sessions.to_proto_session_info(session_id) {
            Some(info) => info,
            None => {
                warn!("publish_session_meta: session {} not found", session_id);
                return Ok(());
            }
        };

        let envelope = teamclaw::SessionMetaEnvelope {
            session: Some(session_info),
        };
        let topic = self.topics.session_meta(session_id);
        let payload = envelope.encode_to_vec();
        self.client
            .publish(topic, QoS::AtLeastOnce, true, payload)
            .await?;
        Ok(())
    }

    /// Publish the team's session index as a retained message.
    async fn publish_session_index(&self) -> crate::error::Result<()> {
        let index = self.sessions.to_proto_index();
        let topic = self.topics.sessions();
        let payload = index.encode_to_vec();
        self.client
            .publish(topic, QoS::AtLeastOnce, true, payload)
            .await?;
        Ok(())
    }

    /// Subscribe to all topics for a given session.
    async fn subscribe_session(&self, session_id: &str) -> crate::error::Result<()> {
        self.client
            .subscribe(self.topics.session_messages(session_id), QoS::AtLeastOnce)
            .await?;
        self.client
            .subscribe(self.topics.session_meta(session_id), QoS::AtLeastOnce)
            .await?;
        self.client
            .subscribe(self.topics.session_workitems(session_id), QoS::AtLeastOnce)
            .await?;
        self.client
            .subscribe(self.topics.session_presence(session_id), QoS::AtLeastOnce)
            .await?;
        Ok(())
    }
}

// --- Helpers ---

fn actor_type_to_string(actor_type: i32) -> String {
    match actor_type {
        x if x == teamclaw::ActorType::Human as i32 => "human",
        x if x == teamclaw::ActorType::PersonalAgent as i32 => "personal_agent",
        x if x == teamclaw::ActorType::RoleAgent as i32 => "role_agent",
        _ => "unknown",
    }
    .to_string()
}

fn message_kind_to_string(kind: i32) -> String {
    match kind {
        x if x == teamclaw::MessageKind::Text as i32 => "text",
        x if x == teamclaw::MessageKind::System as i32 => "system",
        x if x == teamclaw::MessageKind::WorkEvent as i32 => "work_event",
        _ => "unknown",
    }
    .to_string()
}

fn work_item_status_to_string(status: i32) -> String {
    match status {
        x if x == teamclaw::WorkItemStatus::Open as i32 => "open",
        x if x == teamclaw::WorkItemStatus::InProgress as i32 => "in_progress",
        x if x == teamclaw::WorkItemStatus::Done as i32 => "done",
        _ => "unknown",
    }
    .to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::teamclaw::{StoredClaim, StoredCollabSession, StoredParticipant, WorkItemStore};
    use chrono::Utc;
    use std::path::Path;
    use tempfile::TempDir;

    fn dummy_session_manager(config_dir: &Path) -> SessionManager {
        let (client, _eventloop) = rumqttc::AsyncClient::new(
            rumqttc::MqttOptions::new("test", "localhost", 1883),
            10,
        );
        SessionManager::new(
            client,
            "team1",
            "dev-a",
            config_dir.to_path_buf(),
            false,
            None,
        )
        .unwrap()
    }

    fn make_session(id: &str) -> StoredCollabSession {
        StoredCollabSession {
            session_id: id.to_string(),
            session_type: "collab".to_string(),
            team_id: "team1".to_string(),
            title: format!("Session {}", id),
            host_device_id: "dev-a".to_string(),
            created_by: "user1".to_string(),
            created_at: Utc::now(),
            summary: String::new(),
            participants: vec![],
            primary_agent_id: String::new(),
        }
    }

    fn make_agent_participant(actor_id: &str) -> StoredParticipant {
        StoredParticipant {
            actor_id: actor_id.to_string(),
            actor_type: "personal_agent".to_string(),
            display_name: actor_id.to_string(),
            joined_at: Utc::now(),
        }
    }

    fn make_human_participant(actor_id: &str) -> StoredParticipant {
        StoredParticipant {
            actor_id: actor_id.to_string(),
            actor_type: "human".to_string(),
            display_name: actor_id.to_string(),
            joined_at: Utc::now(),
        }
    }

    fn make_message(session_id: &str, mentions: Vec<String>) -> teamclaw::Message {
        teamclaw::Message {
            message_id: "msg1".to_string(),
            session_id: session_id.to_string(),
            sender_actor_id: "human1".to_string(),
            kind: teamclaw::MessageKind::Text as i32,
            content: "hello".to_string(),
            created_at: Utc::now().timestamp(),
            mentions,
            ..Default::default()
        }
    }

    // --- agents_to_activate tests ---

    #[test]
    fn test_agents_to_activate_no_session() {
        let tmp = TempDir::new().unwrap();
        let sm = dummy_session_manager(tmp.path());
        let msg = make_message("nonexistent", vec![]);
        let result = sm.agents_to_activate("nonexistent", &msg);
        assert!(result.is_empty());
    }

    #[test]
    fn test_agents_to_activate_session_no_agents() {
        let tmp = TempDir::new().unwrap();
        let mut sm = dummy_session_manager(tmp.path());

        let mut session = make_session("s1");
        session.participants.push(make_human_participant("human1"));
        sm.sessions.upsert(session);

        let msg = make_message("s1", vec![]);
        let result = sm.agents_to_activate("s1", &msg);
        assert!(result.is_empty());
    }

    #[test]
    fn test_agents_to_activate_sole_agent_gets_all_messages() {
        let tmp = TempDir::new().unwrap();
        let mut sm = dummy_session_manager(tmp.path());

        let mut session = make_session("s1");
        session.participants.push(make_human_participant("human1"));
        session.participants.push(make_agent_participant("agent1"));
        sm.sessions.upsert(session);

        // No mentions — sole agent still receives it
        let msg = make_message("s1", vec![]);
        let result = sm.agents_to_activate("s1", &msg);
        assert_eq!(result, vec!["agent1".to_string()]);
    }

    #[test]
    fn test_agents_to_activate_two_agents_mentioned_one() {
        let tmp = TempDir::new().unwrap();
        let mut sm = dummy_session_manager(tmp.path());

        let mut session = make_session("s1");
        session.participants.push(make_agent_participant("agent1"));
        session.participants.push(make_agent_participant("agent2"));
        sm.sessions.upsert(session);

        let msg = make_message("s1", vec!["agent1".to_string()]);
        let result = sm.agents_to_activate("s1", &msg);
        assert_eq!(result, vec!["agent1".to_string()]);
    }

    #[test]
    fn test_agents_to_activate_two_agents_no_mention_returns_empty() {
        let tmp = TempDir::new().unwrap();
        let mut sm = dummy_session_manager(tmp.path());

        let mut session = make_session("s1");
        session.participants.push(make_agent_participant("agent1"));
        session.participants.push(make_agent_participant("agent2"));
        sm.sessions.upsert(session);

        let msg = make_message("s1", vec![]);
        let result = sm.agents_to_activate("s1", &msg);
        assert!(result.is_empty());
    }

    #[test]
    fn test_agents_to_activate_sender_is_agent_still_returned() {
        // Filtering out the sender happens in server.rs, not here.
        // The method should still return the agent even if they sent the message.
        let tmp = TempDir::new().unwrap();
        let mut sm = dummy_session_manager(tmp.path());

        let mut session = make_session("s1");
        session.participants.push(make_agent_participant("agent1"));
        sm.sessions.upsert(session);

        let mut msg = make_message("s1", vec![]);
        msg.sender_actor_id = "agent1".to_string();

        let result = sm.agents_to_activate("s1", &msg);
        assert_eq!(result, vec!["agent1".to_string()]);
    }

    // --- agents_to_activate_for_work_item tests ---

    #[test]
    fn test_work_item_claimed_returns_claimant() {
        let tmp = TempDir::new().unwrap();
        let sm = dummy_session_manager(tmp.path());

        let claim = teamclaw::Claim {
            claim_id: "c1".to_string(),
            work_item_id: "w1".to_string(),
            actor_id: "agent1".to_string(),
            claimed_at: Utc::now().timestamp(),
        };
        let event = teamclaw::WorkItemEvent {
            event: Some(teamclaw::work_item_event::Event::Claimed(claim)),
        };

        let result = sm.agents_to_activate_for_work_item("s1", &event);
        assert_eq!(result, vec!["agent1".to_string()]);
    }

    #[test]
    fn test_work_item_updated_returns_all_claimants() {
        let tmp = TempDir::new().unwrap();
        let sm = dummy_session_manager(tmp.path());

        // Set up WorkItemStore on disk with two claims for "w1"
        let mut store = WorkItemStore::default();
        store.claims.push(StoredClaim {
            claim_id: "c1".to_string(),
            work_item_id: "w1".to_string(),
            actor_id: "agent1".to_string(),
            claimed_at: Utc::now(),
        });
        store.claims.push(StoredClaim {
            claim_id: "c2".to_string(),
            work_item_id: "w1".to_string(),
            actor_id: "agent2".to_string(),
            claimed_at: Utc::now(),
        });
        store.save(tmp.path(), "s1").unwrap();

        let work_item = teamclaw::WorkItem {
            work_item_id: "w1".to_string(),
            session_id: "s1".to_string(),
            ..Default::default()
        };
        let event = teamclaw::WorkItemEvent {
            event: Some(teamclaw::work_item_event::Event::Updated(work_item)),
        };

        let mut result = sm.agents_to_activate_for_work_item("s1", &event);
        result.sort();
        assert_eq!(result, vec!["agent1".to_string(), "agent2".to_string()]);
    }

    #[test]
    fn test_work_item_submitted_returns_other_claimants() {
        let tmp = TempDir::new().unwrap();
        let sm = dummy_session_manager(tmp.path());

        // agent1 and agent2 claimed w1; agent1 submits — only agent2 should be notified
        let mut store = WorkItemStore::default();
        store.claims.push(StoredClaim {
            claim_id: "c1".to_string(),
            work_item_id: "w1".to_string(),
            actor_id: "agent1".to_string(),
            claimed_at: Utc::now(),
        });
        store.claims.push(StoredClaim {
            claim_id: "c2".to_string(),
            work_item_id: "w1".to_string(),
            actor_id: "agent2".to_string(),
            claimed_at: Utc::now(),
        });
        store.save(tmp.path(), "s1").unwrap();

        let submission = teamclaw::Submission {
            submission_id: "sub1".to_string(),
            work_item_id: "w1".to_string(),
            actor_id: "agent1".to_string(), // submitter
            content: "done".to_string(),
            submitted_at: Utc::now().timestamp(),
        };
        let event = teamclaw::WorkItemEvent {
            event: Some(teamclaw::work_item_event::Event::Submitted(submission)),
        };

        let result = sm.agents_to_activate_for_work_item("s1", &event);
        assert_eq!(result, vec!["agent2".to_string()]);
    }

    #[test]
    fn test_work_item_created_returns_empty() {
        let tmp = TempDir::new().unwrap();
        let sm = dummy_session_manager(tmp.path());

        let work_item = teamclaw::WorkItem {
            work_item_id: "w1".to_string(),
            session_id: "s1".to_string(),
            ..Default::default()
        };
        let event = teamclaw::WorkItemEvent {
            event: Some(teamclaw::work_item_event::Event::Created(work_item)),
        };

        let result = sm.agents_to_activate_for_work_item("s1", &event);
        assert!(result.is_empty());
    }

    // --- sessions_for_agent tests ---

    #[test]
    fn test_sessions_for_agent_in_two_sessions() {
        let tmp = TempDir::new().unwrap();
        let mut sm = dummy_session_manager(tmp.path());

        let mut s1 = make_session("s1");
        s1.participants.push(make_agent_participant("agent1"));
        sm.sessions.upsert(s1);

        let mut s2 = make_session("s2");
        s2.participants.push(make_agent_participant("agent1"));
        sm.sessions.upsert(s2);

        // s3 does not have agent1
        let mut s3 = make_session("s3");
        s3.participants.push(make_agent_participant("agent2"));
        sm.sessions.upsert(s3);

        let mut result = sm.sessions_for_agent("agent1");
        result.sort();
        assert_eq!(result, vec!["s1".to_string(), "s2".to_string()]);
    }

    #[test]
    fn test_sessions_for_agent_not_in_any_session() {
        let tmp = TempDir::new().unwrap();
        let mut sm = dummy_session_manager(tmp.path());

        let mut s1 = make_session("s1");
        s1.participants.push(make_agent_participant("agent2"));
        sm.sessions.upsert(s1);

        let result = sm.sessions_for_agent("agent1");
        assert!(result.is_empty());
    }
}
