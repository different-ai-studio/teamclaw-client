import Foundation
import SwiftProtobuf
import SwiftData

@Observable
@MainActor
public final class TeamclawService {
    public var sessions: [Session] = []
    public var isConnected = false

    private var mqtt: MQTTService?
    public var mqttRef: MQTTService? { mqtt }
    private var teamId: String = ""
    private var deviceId: String = ""
    private var peerId: String = ""
    /// Member id of the local actor, resolved from the retained device peer
    /// list by matching our own peer_id. Populated once
    /// PeerList arrives; used as `sender_actor_id` on outgoing RPCs so the
    /// daemon records the creator as a member rather than a device.
    public private(set) var localMemberId: String = ""
    public private(set) var localDisplayName: String = ""
    private var subscribedSessionMetaActorID: String?
    private var listenerTask: Task<Void, Never>?
    private var modelContainer: ModelContainer?

    public var currentHumanActorId: String? {
        localMemberId.isEmpty ? nil : localMemberId
    }

    public init() {}

    // MARK: - Lifecycle

    public func start(
        mqtt: MQTTService,
        teamId: String,
        deviceId: String,
        peerId: String,
        modelContext: ModelContext
    ) {
        self.mqtt = mqtt
        self.teamId = teamId
        self.deviceId = deviceId
        self.peerId = peerId

        listenerTask?.cancel()

        let container = modelContext.container
        self.modelContainer = container
        let ctx = ModelContext(container)

        // Load cached sessions immediately
        sessions = (try? ctx.fetch(FetchDescriptor<Session>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        ))) ?? []

        listenerTask = Task {
            // Wait for MQTT connection (up to 15s)
            var waited = 0
            while mqtt.connectionState != .connected {
                try? await Task.sleep(for: .milliseconds(200))
                if Task.isCancelled { return }
                waited += 200
                if waited >= 15_000 {
                    print("[TeamclawService] timed out waiting for MQTT connection")
                    return
                }
            }

            let stream = mqtt.messages()

            // Subscribe to core teamclaw topics
            try? await mqtt.subscribe(MQTTTopics.teamSessions(teamID: teamId))
            try? await mqtt.subscribe(MQTTTopics.teamMembers(teamID: teamId))
            // Subscribe to the legacy peer-scoped invite topic first so older
            // senders still reach us until all clients publish member-scoped
            // invite targets. Once we resolve localMemberId from PeerList we
            // additionally subscribe to the canonical member-scoped topic.
            try? await mqtt.subscribe(MQTTTopics.userInvites(teamID: teamId, actorID: peerId))
            try? await mqtt.subscribe(MQTTTopics.rpcResponseWildcard(teamID: teamId, deviceID: deviceId))
            try? await mqtt.subscribe(MQTTTopics.teamTasks(teamID: teamId))
            // amux-side peer list — used to resolve our local member id.
            try? await mqtt.subscribe(MQTTTopics.devicePeers(teamID: teamId, deviceID: deviceId))

            isConnected = true
            print("[TeamclawService] subscribed to teamclaw topics for team: \(teamId)")

            for await incoming in stream {
                if Task.isCancelled { break }
                await handleIncoming(incoming, modelContext: ctx)
            }

            isConnected = false
        }
    }

    public func stop() {
        listenerTask?.cancel()
        listenerTask = nil
        isConnected = false
        subscribedSessionMetaActorID = nil
    }

    // MARK: - Message Dispatch

    private func handleIncoming(_ incoming: MQTTIncoming, modelContext: ModelContext) async {
        let topic = incoming.topic

        if topic == MQTTTopics.devicePeers(teamID: teamId, deviceID: deviceId) {
            if let list = try? Amux_PeerList(serializedBytes: incoming.payload) {
                if let mine = list.peers.first(where: { $0.peerID == peerId }) {
                    if !mine.memberID.isEmpty, mine.memberID != localMemberId {
                        localMemberId = mine.memberID
                        Task { await subscribeToCurrentActorTopics(actorID: mine.memberID) }
                    }
                    if !mine.displayName.isEmpty {
                        localDisplayName = mine.displayName
                    }
                }
            }
            return
        }

        if topic == MQTTTopics.teamSessions(teamID: teamId) {
            guard let index = try? Teamclaw_SessionIndex(serializedBytes: incoming.payload) else {
                print("[TeamclawService] failed to decode SessionIndex from topic: \(topic)")
                return
            }
            syncSessionIndex(index, modelContext: modelContext)
            return
        }

        if topic.contains("/session/") && topic.hasSuffix("/messages") {
            guard let envelope = try? Teamclaw_SessionMessageEnvelope(serializedBytes: incoming.payload) else {
                print("[TeamclawService] failed to decode SessionMessageEnvelope from topic: \(topic)")
                return
            }
            if envelope.hasMessage {
                syncMessage(envelope.message, modelContext: modelContext)
            }
            return
        }

        if topic == MQTTTopics.teamTasks(teamID: teamId) {
            guard let event = try? Teamclaw_TaskEvent(serializedBytes: incoming.payload) else {
                print("[TeamclawService] failed to decode TaskEvent from global topic")
                return
            }
            syncTaskEvent(event, modelContext: modelContext)
            return
        }

        if topic.contains("/session/") && topic.hasSuffix("/tasks") {
            guard let event = try? Teamclaw_TaskEvent(serializedBytes: incoming.payload) else {
                print("[TeamclawService] failed to decode TaskEvent from topic: \(topic)")
                return
            }
            syncTaskEvent(event, modelContext: modelContext)
            return
        }

        if topic.hasSuffix("/invites") {
            guard let envelope = try? Teamclaw_InviteEnvelope(serializedBytes: incoming.payload) else {
                print("[TeamclawService] failed to decode InviteEnvelope from topic: \(topic)")
                return
            }
            if envelope.hasInvite {
                handleInvite(envelope.invite)
            }
            return
        }

        if topic.contains("/session/") && topic.hasSuffix("/meta") {
            guard let envelope = try? Teamclaw_SessionMetaEnvelope(serializedBytes: incoming.payload) else {
                print("[TeamclawService] failed to decode SessionMetaEnvelope from topic: \(topic)")
                return
            }
            if envelope.hasSession {
                syncSessionMeta(envelope.session, modelContext: modelContext)
                subscribeToSession(envelope.session.sessionID)
            }
            return
        }
    }

    // MARK: - Sync Handlers

    private func syncSessionIndex(_ index: Teamclaw_SessionIndex, modelContext: ModelContext) {
        for entry in index.sessions {
            let id = entry.sessionID
            let descriptor = FetchDescriptor<Session>(
                predicate: #Predicate { $0.sessionId == id }
            )
            if let existing = (try? modelContext.fetch(descriptor))?.first {
                existing.title = entry.title
                existing.hostDeviceId = entry.hostDeviceID
                existing.participantCount = Int(entry.participantCount)
                existing.lastMessagePreview = entry.lastMessagePreview
                if entry.lastMessageAt > 0 {
                    existing.lastMessageAt = Date(timeIntervalSince1970: TimeInterval(entry.lastMessageAt))
                }
                let sessionTypeStr: String
                switch entry.sessionType {
                case .control: sessionTypeStr = "control"
                case .collab: sessionTypeStr = "collab"
                default: sessionTypeStr = "collab"
                }
                existing.mode = sessionTypeStr
            } else {
                let sessionTypeStr: String
                switch entry.sessionType {
                case .control: sessionTypeStr = "control"
                case .collab: sessionTypeStr = "collab"
                default: sessionTypeStr = "collab"
                }
                let session = Session(
                    sessionId: entry.sessionID,
                    mode: sessionTypeStr,
                    teamId: teamId,
                    title: entry.title,
                    hostDeviceId: entry.hostDeviceID,
                    createdAt: entry.createdAt > 0 ? Date(timeIntervalSince1970: TimeInterval(entry.createdAt)) : .now,
                    participantCount: Int(entry.participantCount),
                    lastMessagePreview: entry.lastMessagePreview,
                    lastMessageAt: entry.lastMessageAt > 0
                        ? Date(timeIntervalSince1970: TimeInterval(entry.lastMessageAt))
                        : nil
                )
                modelContext.insert(session)
            }
        }
        try? modelContext.save()
        sessions = (try? modelContext.fetch(FetchDescriptor<Session>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        ))) ?? []
    }

    private func syncSessionMeta(_ proto: Teamclaw_SessionInfo, modelContext: ModelContext) {
        let sessionId = proto.sessionID
        guard !sessionId.isEmpty else { return }

        let descriptor = FetchDescriptor<Session>(
            predicate: #Predicate { $0.sessionId == sessionId }
        )
        let existing = (try? modelContext.fetch(descriptor))?.first ?? {
            let created = Session(
                sessionId: sessionId,
                mode: proto.sessionType == .control ? "control" : "collab",
                teamId: proto.teamID,
                title: proto.title,
                hostDeviceId: proto.hostDeviceID,
                createdBy: proto.createdBy,
                createdAt: proto.createdAt > 0
                    ? Date(timeIntervalSince1970: TimeInterval(proto.createdAt))
                    : .now,
                summary: proto.summary,
                participantCount: proto.participants.count,
                lastMessagePreview: proto.lastMessagePreview,
                lastMessageAt: proto.lastMessageAt > 0
                    ? Date(timeIntervalSince1970: TimeInterval(proto.lastMessageAt))
                    : nil,
                taskId: proto.taskID
            )
            created.primaryAgentId = proto.primaryAgentID.isEmpty ? nil : proto.primaryAgentID
            modelContext.insert(created)
            return created
        }()

        existing.primaryAgentId = proto.primaryAgentID.isEmpty ? nil : proto.primaryAgentID
        existing.mode = proto.sessionType == .control ? "control" : "collab"
        existing.teamId = proto.teamID
        existing.hostDeviceId = proto.hostDeviceID
        existing.createdBy = proto.createdBy
        existing.createdAt = proto.createdAt > 0
            ? Date(timeIntervalSince1970: TimeInterval(proto.createdAt))
            : existing.createdAt
        existing.participantCount = proto.participants.count
        if !proto.title.isEmpty { existing.title = proto.title }
        if !proto.summary.isEmpty { existing.summary = proto.summary }
        if !proto.taskID.isEmpty { existing.taskId = proto.taskID }
        if !proto.lastMessagePreview.isEmpty { existing.lastMessagePreview = proto.lastMessagePreview }
        if proto.lastMessageAt > 0 {
            existing.lastMessageAt = Date(timeIntervalSince1970: TimeInterval(proto.lastMessageAt))
        }
        try? modelContext.save()
    }

    private func syncMessage(_ message: Teamclaw_Message, modelContext: ModelContext) {
        let msgId = message.messageID
        let descriptor = FetchDescriptor<SessionMessage>(
            predicate: #Predicate { $0.messageId == msgId }
        )
        guard (try? modelContext.fetch(descriptor))?.first == nil else {
            // Already exists, skip
            return
        }

        let kindStr: String
        switch message.kind {
        case .text: kindStr = "text"
        case .system: kindStr = "system"
        case .workEvent: kindStr = "work_event"
        default: kindStr = "text"
        }

        let sessionMessage = SessionMessage(
            messageId: message.messageID,
            sessionId: message.sessionID,
            senderActorId: message.senderActorID,
            kind: kindStr,
            content: message.content,
            createdAt: message.createdAt > 0
                ? Date(timeIntervalSince1970: TimeInterval(message.createdAt))
                : .now,
            replyToMessageId: message.replyToMessageID,
            mentions: message.mentions.joined(separator: ",")
        )
        sessionMessage.model = message.model.isEmpty ? nil : message.model
        modelContext.insert(sessionMessage)

        let messageSessionId = message.sessionID
        let sessionDescriptor = FetchDescriptor<Session>(
            predicate: #Predicate { $0.sessionId == messageSessionId }
        )
        if let session = (try? modelContext.fetch(sessionDescriptor))?.first {
            session.lastMessagePreview = String(message.content.prefix(140))
            session.lastMessageAt = message.createdAt > 0
                ? Date(timeIntervalSince1970: TimeInterval(message.createdAt))
                : .now
        }
        try? modelContext.save()
    }

    private func handleInvite(_ invite: Teamclaw_Invite) {
        print("[TeamclawService] received invite for session: \(invite.sessionID)")
        guard let mqtt else { return }
        let sid = invite.sessionID
        subscribeToSession(sid)

        guard let actorId = canonicalHumanActorId(for: invite) else {
            print("[TeamclawService] refusing to join invite before canonical human actor id resolves")
            return
        }

        // Send JoinSessionRequest RPC to session host
        var participant = Teamclaw_Participant()
        participant.actorID = actorId
        participant.actorType = .human
        participant.displayName = canonicalHumanDisplayName(fallbackActorId: actorId)
        participant.joinedAt = Int64(Date().timeIntervalSince1970)

        var joinReq = Teamclaw_JoinSessionRequest()
        joinReq.sessionID = sid
        joinReq.participant = participant

        var rpcReq = Teamclaw_RpcRequest()
        rpcReq.requestID = String(UUID().uuidString.prefix(8).lowercased())
        rpcReq.senderDeviceID = deviceId
        rpcReq.method = .joinSession(joinReq)

        let topic = MQTTTopics.rpcRequest(teamID: teamId, deviceID: invite.hostDeviceID, requestID: rpcReq.requestID)
        if let data = try? rpcReq.serializedData() {
            Task {
                try? await mqtt.publish(topic: topic, payload: data, retain: false)
            }
        }
    }

    private func syncTaskEvent(_ event: Teamclaw_TaskEvent, modelContext: ModelContext) {
        let task: Teamclaw_Task
        switch event.event {
        case .created(let item):
            task = item
        case .updated(let item):
            task = item
        case .claimed(let claim):
            let claimItemId = claim.taskID
            let claimDesc = FetchDescriptor<SessionTask>(
                predicate: #Predicate { $0.taskId == claimItemId }
            )
            if let existing = (try? modelContext.fetch(claimDesc))?.first {
                if existing.status == "open" {
                    existing.status = "in_progress"
                    try? modelContext.save()
                }
            }
            return
        case .submitted(let sub):
            let subItemId = sub.taskID
            let subDesc = FetchDescriptor<SessionTask>(
                predicate: #Predicate { $0.taskId == subItemId }
            )
            if let existing = (try? modelContext.fetch(subDesc))?.first {
                existing.status = "done"
                try? modelContext.save()
            }
            return
        case .none:
            return
        }

        let itemId = task.taskID
        let descriptor = FetchDescriptor<SessionTask>(
            predicate: #Predicate { $0.taskId == itemId }
        )

        let statusStr: String
        switch task.status {
        case .open: statusStr = "open"
        case .inProgress: statusStr = "in_progress"
        case .done: statusStr = "done"
        default: statusStr = "open"
        }

        if let existing = (try? modelContext.fetch(descriptor))?.first {
            existing.title = task.title
            existing.taskDescription = task.description_p
            existing.status = statusStr
            existing.parentTaskId = task.parentID
            existing.archived = task.archived
            existing.workspaceId = task.workspaceID
        } else {
            let item = SessionTask(
                taskId: task.taskID,
                sessionId: task.sessionID,
                workspaceId: task.workspaceID,
                title: task.title,
                taskDescription: task.description_p,
                status: statusStr,
                parentTaskId: task.parentID,
                createdBy: task.createdBy,
                createdAt: task.createdAt > 0
                    ? Date(timeIntervalSince1970: TimeInterval(task.createdAt))
                    : .now,
                archived: task.archived
            )
            modelContext.insert(item)
        }
        try? modelContext.save()
    }

    // MARK: - Outbound

    /// Send a text message to a shared session.
    ///
    /// - Parameter modelId: Optional model identifier the user picked in the composer.
    ///   Forwarded via ``Teamclaw_Message/model`` and proxied to the agent's session by
    ///   the daemon's collab→agent dispatch path, which calls `send_set_model` before
    ///   `send_prompt` when the model differs from the agent's current model.
    public func sendMessage(sessionId: String, content: String, modelId: String? = nil) {
        guard let mqtt else { return }
        guard let actorId = currentHumanActorId else {
            print("[TeamclawService] refusing to send session message before localMemberId resolves")
            return
        }
        var message = Teamclaw_Message()
        message.messageID = UUID().uuidString
        message.sessionID = sessionId
        message.senderActorID = actorId
        message.kind = .text
        message.content = content
        message.createdAt = Int64(Date().timeIntervalSince1970)
        if let modelId, !modelId.isEmpty {
            message.model = modelId
        }

        var envelope = Teamclaw_SessionMessageEnvelope()
        envelope.message = message

        guard let data = try? envelope.serializedData() else {
            print("[TeamclawService] failed to serialize SessionMessageEnvelope")
            return
        }

        let topic = MQTTTopics.sessionMessages(teamID: teamId, sessionID: sessionId)
        Task {
            try? await mqtt.publish(topic: topic, payload: data, retain: false)
        }
    }

    public func makeCreateSessionRequest(
        teamId: String,
        title: String,
        summary: String,
        inviteActorIds: [String] = [],
        taskId: String = ""
    ) -> Teamclaw_CreateSessionRequest {
        var createReq = Teamclaw_CreateSessionRequest()
        createReq.sessionType = .collab
        createReq.teamID = teamId
        createReq.title = title
        createReq.summary = summary
        createReq.inviteActorIds = inviteActorIds
        if !taskId.isEmpty {
            createReq.taskID = taskId
        }
        if let actorId = currentHumanActorId {
            createReq.senderActorID = actorId
        }
        return createReq
    }

    public func createTask(description: String, workspaceId: String = "") async -> Bool {
        guard let mqtt else { return false }

        let title: String
        if description.count <= 50 {
            title = description
        } else {
            let prefix = description.prefix(50)
            if let lastSpace = prefix.lastIndex(of: " ") {
                title = String(prefix[prefix.startIndex..<lastSpace]) + "…"
            } else {
                title = String(prefix) + "…"
            }
        }

        var createReq = Teamclaw_CreateTaskRequest()
        createReq.sessionID = ""
        createReq.title = title
        createReq.description_p = description
        if !workspaceId.isEmpty {
            createReq.workspaceID = workspaceId
        }
        if let actorId = currentHumanActorId {
            createReq.senderActorID = actorId
        }

        var rpcReq = Teamclaw_RpcRequest()
        rpcReq.requestID = String(UUID().uuidString.prefix(8)).lowercased()
        rpcReq.senderDeviceID = deviceId
        rpcReq.method = .createTask(createReq)

        let requestId = rpcReq.requestID
        let topic = MQTTTopics.rpcRequest(teamID: teamId, deviceID: deviceId, requestID: requestId)
        let stream = mqtt.messages()

        guard let data = try? rpcReq.serializedData() else { return false }
        try? await mqtt.publish(topic: topic, payload: data, retain: false)

        let deadline = Date().addingTimeInterval(10)
        for await msg in stream {
            if Date() > deadline { break }
            if msg.topic.contains("/rpc/") && msg.topic.hasSuffix("/res") {
                if let response = try? Teamclaw_RpcResponse(serializedBytes: msg.payload),
                   response.requestID == requestId {
                    return response.success
                }
            }
        }
        return false
    }

    /// Toggles the archived flag on a task. Sends an `UpdateTask` RPC
    /// with only `archived` set (other fields left empty / sentinel).
    /// Does not wait for the RPC response — the authoritative state arrives
    /// via the `TaskEvent.updated` broadcast and flows through
    /// `syncTaskEvent`. The call site typically flips `archived` on the
    /// SwiftData model first for optimistic UI; if the RPC fails, the next
    /// broadcast will reinstate the prior value.
    public func archiveTask(taskId: String, sessionId: String, archived: Bool) async {
        guard let mqtt else { return }

        var update = Teamclaw_UpdateTaskRequest()
        update.sessionID = sessionId
        update.taskID = taskId
        update.archived = archived   // SwiftProtobuf: setting also flips hasArchived=true

        var rpcReq = Teamclaw_RpcRequest()
        rpcReq.requestID = String(UUID().uuidString.prefix(8)).lowercased()
        rpcReq.senderDeviceID = deviceId
        rpcReq.method = .updateTask(update)

        let topic = MQTTTopics.rpcRequest(teamID: teamId, deviceID: deviceId, requestID: rpcReq.requestID)
        guard let data = try? rpcReq.serializedData() else { return }
        try? await mqtt.publish(topic: topic, payload: data, retain: false)
    }

    /// Updates a task's status via `UpdateTask` RPC. Mirrors
    /// `archiveTask` — fire-and-forget; authoritative state arrives
    /// via `TaskEvent.updated` broadcast and flows through
    /// `syncTaskEvent`. The call site typically flips `status` on the
    /// SwiftData model first for optimistic UI; if the RPC fails, the next
    /// broadcast will reinstate the prior value.
    ///
    /// - Parameter status: one of `"open"`, `"in_progress"`, `"done"`.
    ///   Any other value is sent as `.unknown` (which SwiftProtobuf skips,
    ///   producing a no-op update on the daemon side).
    public func updateTaskStatus(taskId: String, sessionId: String, status: String) async {
        guard let mqtt else { return }

        var update = Teamclaw_UpdateTaskRequest()
        update.sessionID = sessionId
        update.taskID = taskId
        update.status = protoStatus(from: status)

        var rpcReq = Teamclaw_RpcRequest()
        rpcReq.requestID = String(UUID().uuidString.prefix(8)).lowercased()
        rpcReq.senderDeviceID = deviceId
        rpcReq.method = .updateTask(update)

        let topic = MQTTTopics.rpcRequest(teamID: teamId, deviceID: deviceId, requestID: rpcReq.requestID)
        guard let data = try? rpcReq.serializedData() else { return }
        try? await mqtt.publish(topic: topic, payload: data, retain: false)
    }

    /// Patches any combination of title, description, and status on a task.
    /// item. Title / description are sent as empty strings when `nil` is
    /// passed (SwiftProtobuf treats empty strings as "unset" on the
    /// daemon side). Status omitted when `nil`. Fire-and-forget.
    public func updateTask(
        taskId: String,
        sessionId: String,
        title: String? = nil,
        description: String? = nil,
        status: String? = nil
    ) async {
        guard let mqtt else { return }

        var update = Teamclaw_UpdateTaskRequest()
        update.sessionID = sessionId
        update.taskID = taskId
        if let title { update.title = title }
        if let description { update.description_p = description }
        if let status { update.status = protoStatus(from: status) }

        var rpcReq = Teamclaw_RpcRequest()
        rpcReq.requestID = String(UUID().uuidString.prefix(8)).lowercased()
        rpcReq.senderDeviceID = deviceId
        rpcReq.method = .updateTask(update)

        let topic = MQTTTopics.rpcRequest(teamID: teamId, deviceID: deviceId, requestID: rpcReq.requestID)
        guard let data = try? rpcReq.serializedData() else { return }
        try? await mqtt.publish(topic: topic, payload: data, retain: false)
    }

    /// Maps the SwiftData `Task.status` string domain to the protobuf
    /// `TaskStatus` enum. Unknown inputs map to `.unknown` — defensive
    /// against future status values landing in the model before this mapper
    /// is updated.
    private func protoStatus(from status: String) -> Teamclaw_TaskStatus {
        switch status {
        case "open": return .open
        case "in_progress": return .inProgress
        case "done": return .done
        default: return .unknown
        }
    }

    public func subscribeToSession(_ sessionId: String) {
        guard let mqtt else { return }
        Task {
            try? await mqtt.subscribe(MQTTTopics.sessionMessages(teamID: teamId, sessionID: sessionId))
            try? await mqtt.subscribe(MQTTTopics.sessionTasks(teamID: teamId, sessionID: sessionId))
            try? await mqtt.subscribe(MQTTTopics.sessionPresence(teamID: teamId, sessionID: sessionId))
            await fetchRecentMessages(sessionId: sessionId)
        }
    }

    private func subscribeToCurrentActorTopics(actorID: String) async {
        guard let mqtt else { return }
        if subscribedSessionMetaActorID != actorID {
            try? await mqtt.subscribe(MQTTTopics.actorSessionMetaWildcard(teamID: teamId, actorID: actorID))
            subscribedSessionMetaActorID = actorID
        }
        try? await mqtt.subscribe(MQTTTopics.userInvites(teamID: teamId, actorID: actorID))
    }

    public func fetchRecentMessages(sessionId: String, beforeCreatedAt: Int64 = 0, pageSize: UInt32 = 100) async {
        guard let mqtt,
              let modelContainer else { return }

        let ctx = ModelContext(modelContainer)
        let descriptor = FetchDescriptor<Session>(
            predicate: #Predicate { $0.sessionId == sessionId }
        )
        guard let session = (try? ctx.fetch(descriptor))?.first else { return }

        var req = Teamclaw_FetchSessionMessagesRequest()
        req.sessionID = sessionId
        req.beforeCreatedAt = beforeCreatedAt
        req.pageSize = pageSize

        var rpcReq = Teamclaw_RpcRequest()
        rpcReq.requestID = String(UUID().uuidString.prefix(8)).lowercased()
        rpcReq.senderDeviceID = deviceId
        rpcReq.method = .fetchSessionMessages(req)

        let topic = MQTTTopics.rpcRequest(teamID: teamId, deviceID: session.hostDeviceId, requestID: rpcReq.requestID)
        guard let data = try? rpcReq.serializedData() else { return }
        try? await mqtt.publish(topic: topic, payload: data, retain: false)

        let stream = mqtt.messages()
        let deadline = Date().addingTimeInterval(10)
        for await msg in stream {
            if Date() > deadline { break }
            guard msg.topic.contains("/rpc/"), msg.topic.hasSuffix("/res"),
                  let response = try? Teamclaw_RpcResponse(serializedBytes: msg.payload),
                  response.requestID == rpcReq.requestID,
                  response.success,
                  case .sessionMessagePage(let page) = response.result else {
                continue
            }

            for message in page.messages {
                syncMessage(message, modelContext: ctx)
            }
            break
        }
    }

    private func canonicalHumanActorId(for invite: Teamclaw_Invite) -> String? {
        if let actorId = currentHumanActorId {
            return actorId
        }
        if !invite.invitedActorID.isEmpty {
            return invite.invitedActorID
        }
        return nil
    }

    private func canonicalHumanDisplayName(fallbackActorId: String) -> String {
        if !localDisplayName.isEmpty {
            return localDisplayName
        }
        if let actorId = currentHumanActorId, actorId == fallbackActorId {
            return actorId
        }
        return fallbackActorId
    }
}
