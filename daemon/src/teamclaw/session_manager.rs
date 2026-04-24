use crate::proto::teamclaw::{self, RpcRequest, RpcResponse};
use crate::mqtt::Topics;
use crate::teamclaw::{
    LivePublisher, MessageStore, NotifyPublisher, RpcServer, StoredClaim, StoredMessage,
    StoredParticipant, StoredSession, StoredSubmission, StoredTask, TaskStore,
    TeamclawSessionStore,
};
use chrono::Utc;
use rumqttc::{AsyncClient, QoS};
use std::collections::{BTreeSet, HashSet, VecDeque};
use std::path::PathBuf;
use tracing::{info, warn};
use uuid::Uuid;

const RECENT_EVENT_CACHE_LIMIT: usize = 512;

pub struct SessionManager {
    topics: Topics,
    client: AsyncClient,
    live_publisher: LivePublisher,
    notify_publisher: NotifyPublisher,
    rpc_server: RpcServer,
    pub(crate) sessions: TeamclawSessionStore,
    sessions_path: PathBuf,
    pub(crate) config_dir: PathBuf,
    device_id: String,
    team_id: String,
    actor_id: Option<String>,
    recent_event_keys: HashSet<String>,
    recent_event_order: VecDeque<String>,
    subscribed_live_sessions: BTreeSet<String>,
    #[cfg(test)]
    skip_live_subscription_io: bool,
}

impl SessionManager {
    pub fn new(
        client: AsyncClient,
        team_id: &str,
        device_id: &str,
        actor_id: Option<String>,
        config_dir: PathBuf,
    ) -> crate::error::Result<Self> {
        let topics = Topics::new(team_id, device_id);
        let live_publisher = LivePublisher::new(
            client.clone(),
            team_id.to_string(),
            device_id.to_string(),
        );
        let notify_publisher = NotifyPublisher::new(client.clone(), team_id.to_string());
        let rpc_server = RpcServer::new(client.clone(), team_id.to_string(), device_id.to_string());
        let sessions_path = TeamclawSessionStore::default_path(&config_dir);
        let sessions = TeamclawSessionStore::load(&sessions_path)?;

        Ok(Self {
            topics,
            client,
            live_publisher,
            notify_publisher,
            rpc_server,
            sessions,
            sessions_path,
            config_dir,
            device_id: device_id.to_string(),
            team_id: team_id.to_string(),
            actor_id,
            recent_event_keys: HashSet::new(),
            recent_event_order: VecDeque::new(),
            subscribed_live_sessions: BTreeSet::new(),
            #[cfg(test)]
            skip_live_subscription_io: false,
        })
    }

    /// Subscribe to all relevant teamclaw topics.
    pub async fn subscribe_all(&mut self) -> crate::error::Result<()> {
        for topic in self.base_subscription_topics() {
            self.client.subscribe(topic, QoS::AtLeastOnce).await?;
        }
        self.refresh_membership_subscriptions().await?;

        Ok(())
    }

    /// Handle a pre-parsed RPC request. Only dispatches session/task-scoped methods.
    ///
    /// Caller is responsible for decoding the wire payload and publishing the response.
    /// Non-session methods are dispatched by `DaemonServer::handle_rpc_request` directly.
    ///
    /// `host_primary_agent_id` is intentionally ignored for session creation.
    /// A session should only gain `primary_agent_id` once an agent actually
    /// joins it, rather than inheriting whichever local agent happened to be
    /// running when the session was created.
    pub async fn handle_rpc_method(
        &mut self,
        request: RpcRequest,
        primary_agent_id: Option<String>,
    ) -> RpcResponse {
        let request_id = request.request_id.clone();
        match request.method.clone() {
            Some(teamclaw::rpc_request::Method::CreateSession(r)) => {
                self.handle_create_session(&request, r, primary_agent_id).await
            }
            Some(teamclaw::rpc_request::Method::FetchSession(r)) => {
                self.handle_fetch_session(&request, r).await
            }
            Some(teamclaw::rpc_request::Method::FetchSessionMessages(r)) => {
                self.handle_fetch_session_messages(&request, r).await
            }
            Some(teamclaw::rpc_request::Method::JoinSession(r)) => {
                self.handle_join_session(&request, r).await
            }
            Some(teamclaw::rpc_request::Method::AddParticipant(r)) => {
                self.handle_add_participant(&request, r).await
            }
            Some(teamclaw::rpc_request::Method::RemoveParticipant(r)) => {
                self.handle_remove_participant(&request, r).await
            }
            Some(teamclaw::rpc_request::Method::CreateTask(r)) => {
                self.handle_create_task(&request, r).await
            }
            Some(teamclaw::rpc_request::Method::ClaimTask(r)) => {
                self.handle_claim_task(&request, r).await
            }
            Some(teamclaw::rpc_request::Method::SubmitTask(r)) => {
                self.handle_submit_task(&request, r).await
            }
            Some(teamclaw::rpc_request::Method::UpdateTask(r)) => {
                self.handle_update_task(&request, r).await
            }
            other => {
                // Non-session methods are dispatched by DaemonServer directly,
                // not SessionManager. If we land here, the caller routed wrong.
                warn!(?other, "SessionManager got non-session RPC method; routing bug");
                RpcResponse {
                    request_id,
                    success: false,
                    error: "method not handled by SessionManager".to_string(),
                    requester_client_id: request.requester_client_id,
                    requester_actor_id: request.requester_actor_id,
                    requester_device_id: request.requester_device_id,
                    result: None,
                }
            }
        }
    }

    // --- RPC Handlers ---

    async fn handle_create_session(
        &mut self,
        req: &RpcRequest,
        r: teamclaw::CreateSessionRequest,
        _host_primary_agent_id: Option<String>,
    ) -> RpcResponse {
        let session_id = Uuid::new_v4().to_string();
        let session_type = match r.session_type {
            x if x == teamclaw::SessionType::Control as i32 => "control",
            _ => "collab",
        };

        let session = StoredSession {
            session_id: session_id.clone(),
            session_type: session_type.to_string(),
            team_id: r.team_id.clone(),
            title: r.title.clone(),
            created_by: if !r.sender_actor_id.is_empty() {
                r.sender_actor_id.clone()
            } else {
                req.sender_device_id.clone()
            },
            created_at: Utc::now(),
            summary: r.summary.clone(),
            task_id: r.task_id.clone(),
            participants: vec![],
            primary_agent_id: String::new(),
        };

        self.sessions.upsert(session);
        if let Err(e) = self.sessions.save(&self.sessions_path) {
            warn!("handle_create_session: failed to save sessions: {}", e);
        }

        if let Err(e) = self.refresh_membership_subscriptions().await {
            warn!(
                session_id = %session_id,
                "handle_create_session: failed to refresh membership subscriptions: {}",
                e
            );
        }

        let session_info = self.sessions.to_proto_session_info(&session_id);
        info!(session_id = %session_id, "session created");

        RpcResponse {
            request_id: req.request_id.clone(),
            success: true,
            error: String::new(),
            requester_client_id: String::new(),
            requester_actor_id: String::new(),
            requester_device_id: String::new(),
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
                requester_client_id: String::new(),
                requester_actor_id: String::new(),
                requester_device_id: String::new(),
                result: Some(teamclaw::rpc_response::Result::SessionInfo(info)),
            },
            None => RpcResponse {
                request_id: req.request_id.clone(),
                success: false,
                error: format!("session {} not found", r.session_id),
                requester_client_id: String::new(),
                requester_actor_id: String::new(),
                requester_device_id: String::new(),
                result: None,
            },
        }
    }

    async fn handle_fetch_session_messages(
        &self,
        req: &RpcRequest,
        r: teamclaw::FetchSessionMessagesRequest,
    ) -> RpcResponse {
        let store = match MessageStore::load(&self.config_dir, &r.session_id) {
            Ok(store) => store,
            Err(e) => {
                return RpcResponse {
                    request_id: req.request_id.clone(),
                    success: false,
                    error: e.to_string(),
                    requester_client_id: String::new(),
                    requester_actor_id: String::new(),
                    requester_device_id: String::new(),
                    result: None,
                };
            }
        };

        let (messages, has_more, next_before_created_at) =
            store.page_before(r.before_created_at, if r.page_size == 0 { 100 } else { r.page_size });
        let page = teamclaw::SessionMessagePage {
            session_id: r.session_id,
            messages: messages.into_iter().map(MessageStore::to_proto).collect(),
            has_more,
            next_before_created_at,
        };

        RpcResponse {
            request_id: req.request_id.clone(),
            success: true,
            error: String::new(),
            requester_client_id: String::new(),
            requester_actor_id: String::new(),
            requester_device_id: String::new(),
            result: Some(teamclaw::rpc_response::Result::SessionMessagePage(page)),
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
                    requester_client_id: String::new(),
                    requester_actor_id: String::new(),
                    requester_device_id: String::new(),
                    result: None,
                };
            }
        };

        let actor_type = actor_type_to_string(participant.actor_type);
        let proto_participant = participant.clone();
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
                if participant_is_agent(participant.actor_type) && session.primary_agent_id.is_empty() {
                    session.primary_agent_id = participant.actor_id.clone();
                }
            }
            None => {
                return RpcResponse {
                    request_id: req.request_id.clone(),
                    success: false,
                    error: format!("session {} not found", r.session_id),
                    requester_client_id: String::new(),
                    requester_actor_id: String::new(),
                    requester_device_id: String::new(),
                    result: None,
                };
            }
        }

        if let Err(e) = self.sessions.save(&self.sessions_path) {
            warn!("handle_join_session: failed to save sessions: {}", e);
        }
        if let Err(e) = self.refresh_membership_subscriptions().await {
            warn!(
                session_id = %r.session_id,
                "handle_join_session: failed to refresh membership subscriptions: {}",
                e
            );
        }
        if let Err(e) = self
            .live_publisher
            .publish_presence_event("presence.joined", &r.session_id, &proto_participant)
            .await
        {
            warn!("handle_join_session: failed to publish live presence event: {}", e);
        }
        for target_device_id in self.membership_refresh_targets(&r.session_id, Some(&req.sender_device_id)) {
            if let Err(e) = self
                .notify_publisher
                .publish_membership_refresh(&target_device_id, &r.session_id, "participant_joined")
                .await
            {
                warn!(
                    target_device_id = %target_device_id,
                    "handle_join_session: failed to publish notify event: {}",
                    e
                );
            }
        }

        let session_info = self.sessions.to_proto_session_info(&r.session_id);
        info!(session_id = %r.session_id, actor_id = %participant.actor_id, "participant joined session");

        RpcResponse {
            request_id: req.request_id.clone(),
            success: true,
            error: String::new(),
            requester_client_id: String::new(),
            requester_actor_id: String::new(),
            requester_device_id: String::new(),
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
                    requester_client_id: String::new(),
                    requester_actor_id: String::new(),
                    requester_device_id: String::new(),
                    result: None,
                };
            }
        };

        let actor_type = actor_type_to_string(participant.actor_type);
        let proto_participant = participant.clone();
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
                if participant_is_agent(participant.actor_type) && session.primary_agent_id.is_empty() {
                    session.primary_agent_id = participant.actor_id.clone();
                }
            }
            None => {
                return RpcResponse {
                    request_id: req.request_id.clone(),
                    success: false,
                    error: format!("session {} not found", r.session_id),
                    requester_client_id: String::new(),
                    requester_actor_id: String::new(),
                    requester_device_id: String::new(),
                    result: None,
                };
            }
        }

        if let Err(e) = self.sessions.save(&self.sessions_path) {
            warn!("handle_add_participant: failed to save sessions: {}", e);
        }
        if let Err(e) = self.refresh_membership_subscriptions().await {
            warn!(
                session_id = %r.session_id,
                "handle_add_participant: failed to refresh membership subscriptions: {}",
                e
            );
        }
        if let Err(e) = self
            .live_publisher
            .publish_presence_event("presence.joined", &r.session_id, &proto_participant)
            .await
        {
            warn!("handle_add_participant: failed to publish live presence event: {}", e);
        }
        for target_device_id in self.membership_refresh_targets(&r.session_id, Some(&req.sender_device_id)) {
            if let Err(e) = self
                .notify_publisher
                .publish_membership_refresh(&target_device_id, &r.session_id, "participant_added")
                .await
            {
                warn!(
                    target_device_id = %target_device_id,
                    "handle_add_participant: failed to publish notify event: {}",
                    e
                );
            }
        }

        let session_info = self.sessions.to_proto_session_info(&r.session_id);
        info!(session_id = %r.session_id, actor_id = %participant.actor_id, "participant added to session");

        RpcResponse {
            request_id: req.request_id.clone(),
            success: true,
            error: String::new(),
            requester_client_id: String::new(),
            requester_actor_id: String::new(),
            requester_device_id: String::new(),
            result: session_info.map(|s| teamclaw::rpc_response::Result::SessionInfo(s)),
        }
    }

    async fn handle_remove_participant(
        &mut self,
        req: &RpcRequest,
        r: teamclaw::RemoveParticipantRequest,
    ) -> RpcResponse {
        let removed_participant = match self.sessions.find_by_id_mut(&r.session_id) {
            Some(session) => {
                let removed = session
                    .participants
                    .iter()
                    .find(|p| p.actor_id == r.actor_id)
                    .cloned();
                session.participants.retain(|p| p.actor_id != r.actor_id);
                removed
            }
            None => {
                return RpcResponse {
                    request_id: req.request_id.clone(),
                    success: false,
                    error: format!("session {} not found", r.session_id),
                    requester_client_id: String::new(),
                    requester_actor_id: String::new(),
                    requester_device_id: String::new(),
                    result: None,
                };
            }
        };

        if let Err(e) = self.sessions.save(&self.sessions_path) {
            warn!("handle_remove_participant: failed to save sessions: {}", e);
        }
        if let Err(e) = self.refresh_membership_subscriptions().await {
            warn!(
                session_id = %r.session_id,
                "handle_remove_participant: failed to refresh membership subscriptions: {}",
                e
            );
        }
        if let Some(participant) = removed_participant.as_ref() {
            let proto_participant = stored_participant_to_proto(participant);
            if let Err(e) = self
                .live_publisher
                .publish_presence_event("presence.left", &r.session_id, &proto_participant)
                .await
            {
                warn!("handle_remove_participant: failed to publish live presence event: {}", e);
            }
        }
        for target_device_id in self.membership_refresh_targets(&r.session_id, Some(&req.sender_device_id)) {
            if let Err(e) = self
                .notify_publisher
                .publish_membership_refresh(&target_device_id, &r.session_id, "participant_removed")
                .await
            {
                warn!(
                    target_device_id = %target_device_id,
                    "handle_remove_participant: failed to publish notify event: {}",
                    e
                );
            }
        }

        let session_info = self.sessions.to_proto_session_info(&r.session_id);
        info!(session_id = %r.session_id, actor_id = %r.actor_id, "participant removed from session");

        RpcResponse {
            request_id: req.request_id.clone(),
            success: true,
            error: String::new(),
            requester_client_id: String::new(),
            requester_actor_id: String::new(),
            requester_device_id: String::new(),
            result: session_info.map(|s| teamclaw::rpc_response::Result::SessionInfo(s)),
        }
    }

    async fn handle_create_task(
        &mut self,
        req: &RpcRequest,
        r: teamclaw::CreateTaskRequest,
    ) -> RpcResponse {
        let task_id = Uuid::new_v4().to_string();
        // Prefer the sender's actor/member id when the client supplies it.
        // Older clients that only set sender_device_id still work, they'll
        // just render as "Unknown" on the current UI.
        let created_by = if !r.sender_actor_id.is_empty() {
            r.sender_actor_id.clone()
        } else {
            req.sender_device_id.clone()
        };
        let stored_item = StoredTask {
            task_id: task_id.clone(),
            session_id: r.session_id.clone(),
            workspace_id: r.workspace_id.clone(),
            title: r.title.clone(),
            description: r.description.clone(),
            status: "open".to_string(),
            parent_id: r.parent_id.clone(),
            created_by,
            created_at: Utc::now(),
            archived: false,
        };

        let store_key = canonical_task_store_key(&r.session_id);

        let mut store = match TaskStore::load(&self.config_dir, store_key) {
            Ok(s) => s,
            Err(e) => {
                warn!("handle_create_task: failed to load task store: {}", e);
                return RpcResponse {
                    request_id: req.request_id.clone(),
                    success: false,
                    error: e.to_string(),
                    requester_client_id: String::new(),
                    requester_actor_id: String::new(),
                    requester_device_id: String::new(),
                    result: None,
                };
            }
        };

        store.add_item(stored_item);

        if let Err(e) = store.save(&self.config_dir, store_key) {
            warn!("handle_create_task: failed to save task store: {}", e);
        }

        let task = store
            .find_item(&task_id)
            .map(|i| store.to_proto_task(i));

        // Publish TaskEvent
        if let Some(ref item) = task {
            let event = teamclaw::TaskEvent {
                event: Some(teamclaw::task_event::Event::Created(item.clone())),
            };
            if !r.session_id.is_empty() {
                if let Err(e) = self
                    .live_publisher
                    .publish_task_event("task.created", &r.session_id, &item.created_by, &event)
                    .await
                {
                    warn!("handle_create_task: failed to publish live task event: {}", e);
                }
            }
        }

        info!(task_id = %task_id, session_id = %r.session_id, "task created");

        RpcResponse {
            request_id: req.request_id.clone(),
            success: true,
            error: String::new(),
            requester_client_id: String::new(),
            requester_actor_id: String::new(),
            requester_device_id: String::new(),
            result: task.map(|t| teamclaw::rpc_response::Result::Task(t)),
        }
    }

    async fn handle_claim_task(
        &mut self,
        req: &RpcRequest,
        r: teamclaw::ClaimTaskRequest,
    ) -> RpcResponse {
        let store_key = canonical_task_store_key(&r.session_id);
        let mut store = match TaskStore::load(&self.config_dir, store_key) {
            Ok(s) => s,
            Err(e) => {
                return RpcResponse {
                    request_id: req.request_id.clone(),
                    success: false,
                    error: e.to_string(),
                    requester_client_id: String::new(),
                    requester_actor_id: String::new(),
                    requester_device_id: String::new(),
                    result: None,
                };
            }
        };

        let claim_id = Uuid::new_v4().to_string();
        let actor_id = if !r.sender_actor_id.is_empty() {
            r.sender_actor_id.clone()
        } else {
            req.sender_device_id.clone()
        };
        let claim = StoredClaim {
            claim_id: claim_id.clone(),
            task_id: r.task_id.clone(),
            actor_id: actor_id.clone(),
            claimed_at: Utc::now(),
        };

        store.add_claim(claim);

        if let Err(e) = store.save(&self.config_dir, store_key) {
            warn!("handle_claim_task: failed to save task store: {}", e);
        }

        let proto_claim = teamclaw::Claim {
            claim_id: claim_id.clone(),
            task_id: r.task_id.clone(),
            actor_id: actor_id.clone(),
            claimed_at: Utc::now().timestamp(),
        };

        // Publish TaskEvent
        let event = teamclaw::TaskEvent {
            event: Some(teamclaw::task_event::Event::Claimed(proto_claim.clone())),
        };
        if !r.session_id.is_empty() {
            if let Err(e) = self
                .live_publisher
                .publish_task_event("task.updated", &r.session_id, &proto_claim.actor_id, &event)
                .await
            {
                warn!("handle_claim_task: failed to publish live claim event: {}", e);
            }
        }

        info!(
            claim_id = %claim_id,
            task_id = %r.task_id,
            session_id = %r.session_id,
            "task claimed"
        );

        RpcResponse {
            request_id: req.request_id.clone(),
            success: true,
            error: String::new(),
            requester_client_id: String::new(),
            requester_actor_id: String::new(),
            requester_device_id: String::new(),
            result: Some(teamclaw::rpc_response::Result::Claim(proto_claim)),
        }
    }

    async fn handle_submit_task(
        &mut self,
        req: &RpcRequest,
        r: teamclaw::SubmitTaskRequest,
    ) -> RpcResponse {
        let store_key = canonical_task_store_key(&r.session_id);
        let mut store = match TaskStore::load(&self.config_dir, store_key) {
            Ok(s) => s,
            Err(e) => {
                return RpcResponse {
                    request_id: req.request_id.clone(),
                    success: false,
                    error: e.to_string(),
                    requester_client_id: String::new(),
                    requester_actor_id: String::new(),
                    requester_device_id: String::new(),
                    result: None,
                };
            }
        };

        let submission_id = Uuid::new_v4().to_string();
        let actor_id = if !r.sender_actor_id.is_empty() {
            r.sender_actor_id.clone()
        } else {
            req.sender_device_id.clone()
        };
        let submission = StoredSubmission {
            submission_id: submission_id.clone(),
            task_id: r.task_id.clone(),
            actor_id: actor_id.clone(),
            content: r.content.clone(),
            submitted_at: Utc::now(),
        };

        store.add_submission(submission);

        if let Err(e) = store.save(&self.config_dir, store_key) {
            warn!("handle_submit_task: failed to save task store: {}", e);
        }

        let proto_submission = teamclaw::Submission {
            submission_id: submission_id.clone(),
            task_id: r.task_id.clone(),
            actor_id: actor_id.clone(),
            content: r.content.clone(),
            submitted_at: Utc::now().timestamp(),
        };

        // Publish TaskEvent
        let event = teamclaw::TaskEvent {
            event: Some(teamclaw::task_event::Event::Submitted(
                proto_submission.clone(),
            )),
        };
        if !r.session_id.is_empty() {
            if let Err(e) = self
                .live_publisher
                .publish_task_event("task.updated", &r.session_id, &proto_submission.actor_id, &event)
                .await
            {
                warn!("handle_submit_task: failed to publish live submission event: {}", e);
            }
        }

        info!(
            submission_id = %submission_id,
            task_id = %r.task_id,
            session_id = %r.session_id,
            "task submitted"
        );

        RpcResponse {
            request_id: req.request_id.clone(),
            success: true,
            error: String::new(),
            requester_client_id: String::new(),
            requester_actor_id: String::new(),
            requester_device_id: String::new(),
            result: Some(teamclaw::rpc_response::Result::Submission(proto_submission)),
        }
    }

    async fn handle_update_task(
        &mut self,
        req: &RpcRequest,
        r: teamclaw::UpdateTaskRequest,
    ) -> RpcResponse {
        let store_key = if r.session_id.is_empty() { "global" } else { &r.session_id };

        let mut store = match TaskStore::load(&self.config_dir, store_key) {
            Ok(s) => s,
            Err(e) => {
                return RpcResponse {
                    request_id: req.request_id.clone(),
                    success: false,
                    error: e.to_string(),
                    requester_client_id: String::new(),
                    requester_actor_id: String::new(),
                    requester_device_id: String::new(),
                    result: None,
                };
            }
        };

        match store.find_item_mut(&r.task_id) {
            Some(item) => {
                if !r.title.is_empty() {
                    item.title = r.title.clone();
                }
                if !r.description.is_empty() {
                    item.description = r.description.clone();
                }
                // Update status if non-zero (unknown is 0)
                if r.status != 0 {
                    item.status = task_status_to_string(r.status);
                }
                if let Some(v) = r.archived {
                    item.archived = v;
                }
            }
            None => {
                return RpcResponse {
                    request_id: req.request_id.clone(),
                    success: false,
                    error: format!("task {} not found", r.task_id),
                    requester_client_id: String::new(),
                    requester_actor_id: String::new(),
                    requester_device_id: String::new(),
                    result: None,
                };
            }
        }

        if let Err(e) = store.save(&self.config_dir, store_key) {
            warn!("handle_update_task: failed to save task store: {}", e);
        }

        let task = store
            .find_item(&r.task_id)
            .map(|i| store.to_proto_task(i));

        // Publish TaskEvent
        if let Some(ref item) = task {
            let event = teamclaw::TaskEvent {
                event: Some(teamclaw::task_event::Event::Updated(item.clone())),
            };
            if !r.session_id.is_empty() {
                if let Err(e) = self
                    .live_publisher
                    .publish_task_event("task.updated", &r.session_id, &req.sender_device_id, &event)
                    .await
                {
                    warn!("handle_update_task: failed to publish live update event: {}", e);
                }
            }
        }

        info!(
            task_id = %r.task_id,
            session_id = %r.session_id,
            archived = ?r.archived,
            "task updated"
        );

        RpcResponse {
            request_id: req.request_id.clone(),
            success: true,
            error: String::new(),
            requester_client_id: String::new(),
            requester_actor_id: String::new(),
            requester_device_id: String::new(),
            result: task.map(|t| teamclaw::rpc_response::Result::Task(t)),
        }
    }

    // --- Public helpers ---

    /// Persist an incoming message for a session.
    pub async fn persist_message(
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
            model: message.model.clone(),
        };

        let mut store = MessageStore::load(&self.config_dir, session_id)?;
        store.append(stored);
        store.save(&self.config_dir, session_id)?;
        Ok(())
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

    /// Returns the agent actor_ids that should be activated for a task event.
    ///
    /// - Claimed → activate the claiming agent
    /// - Updated → activate all agents that claimed the task
    /// - Submitted → activate other claimants (not the submitter)
    pub fn agents_to_activate_for_work_item(
        &self,
        session_id: &str,
        event: &teamclaw::TaskEvent,
    ) -> Vec<String> {
        match &event.event {
            Some(teamclaw::task_event::Event::Claimed(claim)) => {
                vec![claim.actor_id.clone()]
            }
            Some(teamclaw::task_event::Event::Updated(task)) => {
                // Activate all agents that claimed this task
                match TaskStore::load(&self.config_dir, canonical_task_store_key(session_id)) {
                    Ok(store) => store
                        .claims_for_task(&task.task_id)
                        .into_iter()
                        .map(|c| c.actor_id.clone())
                        .collect(),
                    Err(_) => vec![],
                }
            }
            Some(teamclaw::task_event::Event::Submitted(submission)) => {
                // Activate other claimants (not the submitter)
                match TaskStore::load(&self.config_dir, canonical_task_store_key(session_id)) {
                    Ok(store) => store
                        .claims_for_task(&submission.task_id)
                        .into_iter()
                        .filter(|c| c.actor_id != submission.actor_id)
                        .map(|c| c.actor_id.clone())
                        .collect(),
                    Err(_) => vec![],
                }
            }
            Some(teamclaw::task_event::Event::Created(_)) | None => vec![],
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
        let _ = self
            .live_publisher
            .publish_message(session_id, agent_actor_id, &envelope)
            .await;
    }

    pub async fn publish_live_message(
        &self,
        session_id: &str,
        message: &teamclaw::Message,
    ) -> crate::error::Result<()> {
        let envelope = teamclaw::SessionMessageEnvelope {
            message: Some(message.clone()),
        };
        self.live_publisher
            .publish_message(session_id, &message.sender_actor_id, &envelope)
            .await
    }

    pub async fn ensure_session_subscription(
        &mut self,
        _session_id: &str,
    ) -> crate::error::Result<()> {
        self.refresh_membership_subscriptions().await
    }

    pub async fn refresh_membership_subscriptions(&mut self) -> crate::error::Result<()> {
        self.apply_membership_sessions(self.membership_session_ids())
            .await
    }

    pub async fn apply_membership_sessions(
        &mut self,
        session_ids: Vec<String>,
    ) -> crate::error::Result<()> {
        let desired: BTreeSet<String> = session_ids
            .into_iter()
            .filter(|session_id| !session_id.is_empty())
            .collect();

        let to_subscribe: Vec<String> = desired
            .difference(&self.subscribed_live_sessions)
            .cloned()
            .collect();
        let to_unsubscribe: Vec<String> = self
            .subscribed_live_sessions
            .difference(&desired)
            .cloned()
            .collect();

        for session_id in &to_subscribe {
            self.subscribe_session_live(session_id).await?;
            self.request_recent_session_events(session_id).await?;
        }

        for session_id in &to_unsubscribe {
            self.unsubscribe_session_live(session_id).await?;
        }

        self.subscribed_live_sessions = desired;
        Ok(())
    }

    pub fn subscribed_live_sessions(&self) -> Vec<String> {
        self.subscribed_live_sessions.iter().cloned().collect()
    }

    pub fn should_process_message(&mut self, session_id: &str, message_id: &str) -> bool {
        self.record_recent_event(format!("message:{session_id}:{message_id}"))
    }

    pub fn should_process_task_event(
        &mut self,
        session_id: &str,
        event: &teamclaw::TaskEvent,
    ) -> bool {
        let key = match &event.event {
            Some(teamclaw::task_event::Event::Created(task)) => {
                format!("task-created:{session_id}:{}", task.task_id)
            }
            Some(teamclaw::task_event::Event::Updated(task)) => {
                format!("task-updated:{session_id}:{}", task.task_id)
            }
            Some(teamclaw::task_event::Event::Claimed(claim)) => {
                format!("claim:{session_id}:{}", claim.claim_id)
            }
            Some(teamclaw::task_event::Event::Submitted(submission)) => {
                format!("submission:{session_id}:{}", submission.submission_id)
            }
            None => return true,
        };
        self.record_recent_event(key)
    }

    // --- Private helpers ---

    async fn subscribe_session_live(&self, session_id: &str) -> crate::error::Result<()> {
        #[cfg(test)]
        if self.skip_live_subscription_io {
            return Ok(());
        }
        self.client
            .subscribe(self.live_session_topic(session_id), QoS::AtLeastOnce)
            .await?;
        Ok(())
    }

    async fn unsubscribe_session_live(&self, session_id: &str) -> crate::error::Result<()> {
        #[cfg(test)]
        if self.skip_live_subscription_io {
            return Ok(());
        }
        self.client
            .unsubscribe(self.live_session_topic(session_id))
            .await?;
        Ok(())
    }

    fn base_subscription_topics(&self) -> Vec<String> {
        vec![
            self.topics.device_rpc_req(),
            self.topics.device_notify(),
            self.topics.device_rpc_res(),
        ]
    }

    fn live_session_topic(&self, session_id: &str) -> String {
        self.topics.session_live(session_id)
    }

    fn membership_session_ids(&self) -> Vec<String> {
        let local_actor_id = self.actor_id.as_deref();
        self.sessions
            .sessions
            .iter()
            .filter(|session| {
                local_actor_id.is_some_and(|actor_id| {
                    session
                        .participants
                        .iter()
                        .any(|participant| participant.actor_id == actor_id)
                })
            })
            .map(|session| session.session_id.clone())
            .collect()
    }

    async fn request_recent_session_events(&self, _session_id: &str) -> crate::error::Result<()> {
        Ok(())
    }

    fn record_recent_event(&mut self, key: String) -> bool {
        if key.is_empty() {
            return true;
        }
        if self.recent_event_keys.contains(&key) {
            return false;
        }

        self.recent_event_keys.insert(key.clone());
        self.recent_event_order.push_back(key);

        while self.recent_event_order.len() > RECENT_EVENT_CACHE_LIMIT {
            if let Some(oldest) = self.recent_event_order.pop_front() {
                self.recent_event_keys.remove(&oldest);
            }
        }

        true
    }

    fn membership_refresh_targets(
        &self,
        session_id: &str,
        requester_device_id: Option<&str>,
    ) -> Vec<String> {
        let mut targets = Vec::new();

        if let Some(requester_device_id) = requester_device_id {
            if !requester_device_id.is_empty() && requester_device_id != self.device_id {
                targets.push(requester_device_id.to_string());
            }
        }

        // The current request shapes only identify actors being invited/removed,
        // not the target device for those actors, so direct invitee targeting
        // is not possible here without additional membership/device mapping.
        targets
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

fn participant_is_agent(actor_type: i32) -> bool {
    actor_type == teamclaw::ActorType::PersonalAgent as i32
        || actor_type == teamclaw::ActorType::RoleAgent as i32
}

fn stored_participant_to_proto(participant: &StoredParticipant) -> teamclaw::Participant {
    teamclaw::Participant {
        actor_id: participant.actor_id.clone(),
        actor_type: match participant.actor_type.as_str() {
            "human" => teamclaw::ActorType::Human as i32,
            "personal_agent" => teamclaw::ActorType::PersonalAgent as i32,
            "role_agent" => teamclaw::ActorType::RoleAgent as i32,
            _ => teamclaw::ActorType::Unknown as i32,
        },
        display_name: participant.display_name.clone(),
        joined_at: participant.joined_at.timestamp(),
    }
}

fn canonical_task_store_key(session_id: &str) -> &str {
    if session_id.is_empty() { "global" } else { session_id }
}

fn session_type_to_proto(s: &str) -> teamclaw::SessionType {
    match s {
        "control" => teamclaw::SessionType::Control,
        "collab" => teamclaw::SessionType::Collab,
        _ => teamclaw::SessionType::Unknown,
    }
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

fn task_status_to_string(status: i32) -> String {
    match status {
        x if x == teamclaw::TaskStatus::Open as i32 => "open",
        x if x == teamclaw::TaskStatus::InProgress as i32 => "in_progress",
        x if x == teamclaw::TaskStatus::Done as i32 => "done",
        _ => "unknown",
    }
    .to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::teamclaw::{StoredClaim, StoredParticipant, StoredSession, TaskStore};
    use chrono::Utc;
    use std::path::Path;
    use tempfile::TempDir;

    fn dummy_session_manager(config_dir: &Path) -> SessionManager {
        let (client, _eventloop) = rumqttc::AsyncClient::new(
            rumqttc::MqttOptions::new("test", "localhost", 1883),
            10,
        );
        let mut manager = SessionManager::new(
            client,
            "team1",
            "dev-a",
            None,
            config_dir.to_path_buf(),
        )
        .unwrap();
        manager.skip_live_subscription_io = true;
        manager
    }

    fn make_session(id: &str) -> StoredSession {
        StoredSession {
            session_id: id.to_string(),
            session_type: "collab".to_string(),
            team_id: "team1".to_string(),
            title: format!("Session {}", id),
            created_by: "user1".to_string(),
            created_at: Utc::now(),
            summary: String::new(),
            participants: vec![],
            primary_agent_id: String::new(),
            task_id: String::new(),
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

    #[test]
    fn test_membership_refresh_targets_only_include_requester() {
        let tmp = TempDir::new().unwrap();
        let mut sm = dummy_session_manager(tmp.path());

        let targets = sm.membership_refresh_targets("s1", Some("dev-requester"));
        assert_eq!(targets, vec!["dev-requester".to_string()]);
    }

    #[test]
    fn test_membership_refresh_targets_skip_local_requester() {
        let tmp = TempDir::new().unwrap();
        let mut sm = dummy_session_manager(tmp.path());

        let targets = sm.membership_refresh_targets("s1", Some("dev-a"));
        assert!(targets.is_empty());
    }

    #[tokio::test]
    async fn test_apply_membership_sessions_adds_and_removes_live_subscriptions() {
        let tmp = TempDir::new().unwrap();
        let mut sm = dummy_session_manager(tmp.path());

        sm.apply_membership_sessions(vec!["sess-1".to_string(), "sess-2".to_string()])
            .await
            .unwrap();
        assert_eq!(
            sm.subscribed_live_sessions(),
            vec!["sess-1".to_string(), "sess-2".to_string()]
        );

        sm.apply_membership_sessions(vec!["sess-2".to_string()])
            .await
            .unwrap();
        assert_eq!(sm.subscribed_live_sessions(), vec!["sess-2".to_string()]);
    }

    #[tokio::test]
    async fn test_refresh_membership_subscriptions_uses_local_actor_truth() {
        let tmp = TempDir::new().unwrap();
        let (client, _eventloop) = rumqttc::AsyncClient::new(
            rumqttc::MqttOptions::new("test", "localhost", 1883),
            10,
        );
        let mut sm = SessionManager::new(
            client,
            "team1",
            "dev-a",
            Some("member-a".to_string()),
            tmp.path().to_path_buf(),
        )
        .unwrap();
        sm.skip_live_subscription_io = true;

        let mut joined = make_session("joined");
        joined.participants.push(make_human_participant("member-a"));

        let mut unrelated = make_session("unrelated");
        unrelated.participants.push(make_human_participant("someone-else"));

        sm.sessions.upsert(joined);
        sm.sessions.upsert(unrelated);

        sm.refresh_membership_subscriptions().await.unwrap();

        assert_eq!(
            sm.subscribed_live_sessions(),
            vec!["joined".to_string()]
        );
    }

    #[tokio::test]
    async fn test_subscribe_all_rebuilds_live_set_from_membership_truth() {
        let tmp = TempDir::new().unwrap();
        let (client, _eventloop) = rumqttc::AsyncClient::new(
            rumqttc::MqttOptions::new("test", "localhost", 1883),
            10,
        );
        let mut sm = SessionManager::new(
            client,
            "team1",
            "dev-a",
            Some("member-a".to_string()),
            tmp.path().to_path_buf(),
        )
        .unwrap();
        sm.skip_live_subscription_io = true;

        let mut joined = make_session("joined");
        joined.participants.push(make_human_participant("member-a"));

        sm.sessions.upsert(joined);

        sm.subscribe_all().await.unwrap();

        assert_eq!(
            sm.subscribed_live_sessions(),
            vec!["joined".to_string()]
        );
    }

    #[tokio::test]
    async fn test_subscribe_all_reconciles_live_set_after_membership_changes() {
        let tmp = TempDir::new().unwrap();
        let (client, _eventloop) = rumqttc::AsyncClient::new(
            rumqttc::MqttOptions::new("test", "localhost", 1883),
            10,
        );
        let mut sm = SessionManager::new(
            client,
            "team1",
            "dev-a",
            Some("member-a".to_string()),
            tmp.path().to_path_buf(),
        )
        .unwrap();
        sm.skip_live_subscription_io = true;

        let mut joined = make_session("joined");
        joined.participants.push(make_human_participant("member-a"));

        sm.sessions.upsert(joined);
        sm.subscribe_all().await.unwrap();
        assert_eq!(
            sm.subscribed_live_sessions(),
            vec!["joined".to_string()]
        );

        let mut unrelated = make_session("replacement");
        sm.sessions.sessions.clear();
        sm.sessions.upsert(unrelated);

        sm.subscribe_all().await.unwrap();

        assert!(sm.subscribed_live_sessions().is_empty());
    }

    #[test]
    fn test_base_subscription_topics_exclude_retained_session_state_topics() {
        let tmp = TempDir::new().unwrap();
        let mut sm = dummy_session_manager(tmp.path());
        sm.actor_id = Some("member-a".to_string());

        let topics = sm.base_subscription_topics();

        assert!(topics.contains(&"amux/team1/device/dev-a/rpc/req".to_string()));
        assert!(topics.contains(&"amux/team1/device/dev-a/rpc/res".to_string()));
        assert!(topics.contains(&"amux/team1/device/dev-a/notify".to_string()));
        assert!(!topics.contains(&"amux/team1/sessions".to_string()));
        assert!(
            !topics.iter().any(|topic| topic.contains("/actor/member-a/session/"))
        );
    }

    #[test]
    fn test_session_live_topic_is_distinct_from_legacy_rollout_topics() {
        let tmp = TempDir::new().unwrap();
        let sm = dummy_session_manager(tmp.path());

        let live = sm.live_session_topic("s1");

        assert_eq!(live, "amux/team1/session/s1/live");
    }

    #[test]
    fn test_recent_event_dedupe_uses_stable_ids() {
        let tmp = TempDir::new().unwrap();
        let mut sm = dummy_session_manager(tmp.path());

        assert!(sm.should_process_message("s1", "m1"));
        assert!(!sm.should_process_message("s1", "m1"));

        let created = teamclaw::TaskEvent {
            event: Some(teamclaw::task_event::Event::Created(teamclaw::Task {
                task_id: "t1".to_string(),
                session_id: "s1".to_string(),
                ..Default::default()
            })),
        };
        let updated = teamclaw::TaskEvent {
            event: Some(teamclaw::task_event::Event::Updated(teamclaw::Task {
                task_id: "t1".to_string(),
                session_id: "s1".to_string(),
                ..Default::default()
            })),
        };
        assert!(sm.should_process_task_event("s1", &created));
        assert!(!sm.should_process_task_event("s1", &created));
        assert!(sm.should_process_task_event("s1", &updated));
        assert!(!sm.should_process_task_event("s1", &updated));
    }

    #[test]
    fn test_canonical_task_store_key_maps_empty_to_global() {
        assert_eq!(canonical_task_store_key(""), "global");
        assert_eq!(canonical_task_store_key("s1"), "s1");
    }

    // --- agents_to_activate_for_work_item tests ---

    #[test]
    fn test_work_item_claimed_returns_claimant() {
        let tmp = TempDir::new().unwrap();
        let sm = dummy_session_manager(tmp.path());

        let claim = teamclaw::Claim {
            claim_id: "c1".to_string(),
            task_id: "w1".to_string(),
            actor_id: "agent1".to_string(),
            claimed_at: Utc::now().timestamp(),
        };
        let event = teamclaw::TaskEvent {
            event: Some(teamclaw::task_event::Event::Claimed(claim)),
        };

        let result = sm.agents_to_activate_for_work_item("s1", &event);
        assert_eq!(result, vec!["agent1".to_string()]);
    }

    #[test]
    fn test_work_item_updated_returns_all_claimants() {
        let tmp = TempDir::new().unwrap();
        let sm = dummy_session_manager(tmp.path());

        // Set up TaskStore on disk with two claims for "w1"
        let mut store = TaskStore::default();
        store.claims.push(StoredClaim {
            claim_id: "c1".to_string(),
            task_id: "w1".to_string(),
            actor_id: "agent1".to_string(),
            claimed_at: Utc::now(),
        });
        store.claims.push(StoredClaim {
            claim_id: "c2".to_string(),
            task_id: "w1".to_string(),
            actor_id: "agent2".to_string(),
            claimed_at: Utc::now(),
        });
        store.save(tmp.path(), "s1").unwrap();

        let work_item = teamclaw::Task {
            task_id: "w1".to_string(),
            session_id: "s1".to_string(),
            ..Default::default()
        };
        let event = teamclaw::TaskEvent {
            event: Some(teamclaw::task_event::Event::Updated(work_item)),
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
        let mut store = TaskStore::default();
        store.claims.push(StoredClaim {
            claim_id: "c1".to_string(),
            task_id: "w1".to_string(),
            actor_id: "agent1".to_string(),
            claimed_at: Utc::now(),
        });
        store.claims.push(StoredClaim {
            claim_id: "c2".to_string(),
            task_id: "w1".to_string(),
            actor_id: "agent2".to_string(),
            claimed_at: Utc::now(),
        });
        store.save(tmp.path(), "s1").unwrap();

        let submission = teamclaw::Submission {
            submission_id: "sub1".to_string(),
            task_id: "w1".to_string(),
            actor_id: "agent1".to_string(), // submitter
            content: "done".to_string(),
            submitted_at: Utc::now().timestamp(),
        };
        let event = teamclaw::TaskEvent {
            event: Some(teamclaw::task_event::Event::Submitted(submission)),
        };

        let result = sm.agents_to_activate_for_work_item("s1", &event);
        assert_eq!(result, vec!["agent2".to_string()]);
    }

    #[test]
    fn test_work_item_created_returns_empty() {
        let tmp = TempDir::new().unwrap();
        let sm = dummy_session_manager(tmp.path());

        let work_item = teamclaw::Task {
            task_id: "w1".to_string(),
            session_id: "s1".to_string(),
            ..Default::default()
        };
        let event = teamclaw::TaskEvent {
            event: Some(teamclaw::task_event::Event::Created(work_item)),
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
