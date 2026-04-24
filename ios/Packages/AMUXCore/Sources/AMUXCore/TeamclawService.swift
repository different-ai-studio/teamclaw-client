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
    private var foregroundSessionIDsSet: Set<String> = []
    private var listenerTask: Task<Void, Never>?
    private var modelContainer: ModelContainer?
    private var isTestingForegroundLifecycle = false
    internal private(set) var fetchRecentMessagesCalls: [String] = []
    internal private(set) var fetchSessionInfoCalls: [String] = []
    internal private(set) var refreshedSessionIDs: [String] = []

    internal var foregroundSessionIDs: [String] {
        foregroundSessionIDsSet.sorted()
    }

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
        listenerTask?.cancel()
        let container = modelContext.container
        configureRuntime(
            mqtt: mqtt,
            teamId: teamId,
            deviceId: deviceId,
            peerId: peerId,
            modelContainer: container
        )
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
            try? await mqtt.subscribe(MQTTTopics.deviceNotify(teamID: teamId, deviceID: deviceId))
            try? await mqtt.subscribe(MQTTTopics.deviceRpcResponse(teamID: teamId, deviceID: deviceId))
            await rehydrateForegroundSessionSubscriptions(on: mqtt)

            // Phase 2b: peers come from FetchPeers RPC instead of retained
            // devicePeers subscription. One-shot fetch after subscribe; notify
            // handler does follow-ups on peers.changed / members.changed.
            Task { [weak self] in
                guard let self else { return }
                let peers = await self.fetchPeers()
                self.syncPeers(peers)
            }

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
        for sessionId in foregroundSessionIDsSet {
            let topic = MQTTTopics.sessionLive(teamID: teamId, sessionID: sessionId)
            mqtt?.unsubscribeForLifecycleStop(topic)
        }
        foregroundSessionIDsSet.removeAll()
    }

    // MARK: - Message Dispatch

    private func handleIncoming(_ incoming: MQTTIncoming, modelContext: ModelContext) async {
        let topic = incoming.topic

        if topic == MQTTTopics.deviceNotify(teamID: teamId, deviceID: deviceId) {
            // Phase 2b: device/{id}/notify carries two wire shapes during the
            // compat window — new Teamclaw_Notify (event_type + refresh_hint,
            // field numbers 1-3) and legacy NotifyEnvelope (pre-Phase-2b
            // daemons still emit it on membership.refresh). Try Notify first;
            // fall back to NotifyEnvelope for old-format messages.
            let parsed: (eventType: String, refreshHint: String)?
            if let notify = try? Teamclaw_Notify(serializedBytes: incoming.payload) {
                parsed = (notify.eventType, notify.refreshHint)
            } else if let envelope = try? Teamclaw_NotifyEnvelope(serializedBytes: incoming.payload) {
                parsed = (envelope.eventType, envelope.sessionID)
            } else {
                print("[TeamclawService] failed to decode device/notify payload as Notify or NotifyEnvelope")
                return
            }

            guard let (eventType, refreshHint) = parsed else { return }

            switch eventType {
            case "membership.refresh", "members.changed":
                if !refreshHint.isEmpty {
                    await refreshSessionState(for: refreshHint, modelContext: modelContext)
                }
            case "peers.changed":
                let peers = await fetchPeers()
                syncPeers(peers)
            case "workspaces.changed":
                // Placeholder: Task 6 wires the returned array into state.
                _ = await fetchWorkspaces()
            default:
                break
            }
            return
        }

        if topic.contains("/session/") && topic.hasSuffix("/live") {
            guard let envelope = try? Teamclaw_LiveEventEnvelope(serializedBytes: incoming.payload) else {
                print("[TeamclawService] failed to decode LiveEventEnvelope from topic: \(topic)")
                return
            }
            handleLiveEvent(envelope, modelContext: modelContext)
            return
        }

    }

    // MARK: - Sync Handlers

    /// Updates `localMemberId` and `localDisplayName` from a peer list returned
    /// by the FetchPeers RPC. Replaces the former retained devicePeers handler.
    private func syncPeers(_ peers: [Amux_PeerInfo]) {
        guard let mine = peers.first(where: { $0.peerID == peerId }) else { return }
        if !mine.memberID.isEmpty, mine.memberID != localMemberId {
            localMemberId = mine.memberID
        }
        if !mine.displayName.isEmpty {
            localDisplayName = mine.displayName
        }
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

    private func handleLiveEvent(_ envelope: Teamclaw_LiveEventEnvelope, modelContext: ModelContext) {
        if envelope.eventType.hasPrefix("message.") {
            guard let messageEnvelope = try? Teamclaw_SessionMessageEnvelope(serializedBytes: envelope.body) else {
                print("[TeamclawService] failed to decode SessionMessageEnvelope from live event: \(envelope.eventType)")
                return
            }
            if messageEnvelope.hasMessage {
                syncMessage(messageEnvelope.message, modelContext: modelContext)
            }
            return
        }

        if envelope.eventType.hasPrefix("task.") {
            guard let taskEvent = try? Teamclaw_TaskEvent(serializedBytes: envelope.body) else {
                print("[TeamclawService] failed to decode TaskEvent from live event: \(envelope.eventType)")
                return
            }
            syncTaskEvent(taskEvent, modelContext: modelContext)
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

        var messageEnvelope = Teamclaw_SessionMessageEnvelope()
        messageEnvelope.message = message

        let body: Data
        do {
            body = try messageEnvelope.serializedData()
        } catch {
            print("[TeamclawService] failed to serialize SessionMessageEnvelope")
            return
        }

        var live = Teamclaw_LiveEventEnvelope()
        live.eventID = UUID().uuidString
        live.eventType = "message.created"
        live.sessionID = sessionId
        live.actorID = actorId
        live.sentAt = Int64(Date().timeIntervalSince1970)
        live.body = body

        guard let data = try? live.serializedData() else {
            print("[TeamclawService] failed to serialize LiveEventEnvelope")
            return
        }

        let topic = MQTTTopics.sessionLive(teamID: teamId, sessionID: sessionId)
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
        let topic = MQTTTopics.deviceRpcRequest(teamID: teamId, deviceID: deviceId)
        let stream = mqtt.messages()

        guard let data = try? rpcReq.serializedData() else { return false }
        try? await mqtt.publish(topic: topic, payload: data, retain: false)

        let deadline = Date().addingTimeInterval(10)
        for await msg in stream {
            if Date() > deadline { break }
            if msg.topic == MQTTTopics.deviceRpcResponse(teamID: teamId, deviceID: deviceId) {
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

        let topic = MQTTTopics.deviceRpcRequest(teamID: teamId, deviceID: deviceId)
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

        let topic = MQTTTopics.deviceRpcRequest(teamID: teamId, deviceID: deviceId)
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

        let topic = MQTTTopics.deviceRpcRequest(teamID: teamId, deviceID: deviceId)
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
        Task {
            try? await beginForegroundSession(sessionId)
        }
    }

    public func beginForegroundSession(_ sessionId: String) async throws {
        guard !sessionId.isEmpty else { return }
        guard let mqtt else { return }
        guard !foregroundSessionIDsSet.contains(sessionId) else { return }

        let topic = MQTTTopics.sessionLive(teamID: teamId, sessionID: sessionId)
        try await mqtt.subscribe(topic)
        foregroundSessionIDsSet.insert(sessionId)
        await fetchRecentMessagesForForegroundSession(sessionId)
    }

    public func endForegroundSession(_ sessionId: String) async throws {
        guard foregroundSessionIDsSet.contains(sessionId) else { return }
        guard let mqtt else { return }

        let topic = MQTTTopics.sessionLive(teamID: teamId, sessionID: sessionId)
        try await mqtt.unsubscribe(topic)
        foregroundSessionIDsSet.remove(sessionId)
    }

    private func refreshSessionState(for sessionId: String, modelContext: ModelContext) async {
        refreshedSessionIDs.append(sessionId)
        await fetchSessionInfo(sessionId: sessionId, modelContext: modelContext)
        if foregroundSessionIDsSet.contains(sessionId) {
            await fetchRecentMessagesForForegroundSession(sessionId)
        }
    }

    private func fetchSessionInfo(sessionId: String, modelContext: ModelContext) async {
        if isTestingForegroundLifecycle {
            fetchSessionInfoCalls.append(sessionId)
            return
        }

        guard let mqtt else { return }

        let descriptor = FetchDescriptor<Session>(
            predicate: #Predicate { $0.sessionId == sessionId }
        )
        guard let session = (try? modelContext.fetch(descriptor))?.first else {
            return
        }
        guard let targetDeviceID = await rpcTargetDeviceID(for: session.primaryAgentId) else {
            return
        }

        var req = Teamclaw_FetchSessionRequest()
        req.sessionID = sessionId

        var rpcReq = Teamclaw_RpcRequest()
        rpcReq.requestID = String(UUID().uuidString.prefix(8)).lowercased()
        rpcReq.senderDeviceID = deviceId
        rpcReq.method = .fetchSession(req)

        let topic = MQTTTopics.deviceRpcRequest(teamID: teamId, deviceID: targetDeviceID)
        guard let data = try? rpcReq.serializedData() else { return }
        try? await mqtt.publish(topic: topic, payload: data, retain: false)

        let stream = mqtt.messages()
        let deadline = Date().addingTimeInterval(10)
        for await msg in stream {
            if Date() > deadline { break }
            guard msg.topic == MQTTTopics.deviceRpcResponse(teamID: teamId, deviceID: deviceId),
                  let response = try? Teamclaw_RpcResponse(serializedBytes: msg.payload),
                  response.requestID == rpcReq.requestID,
                  response.success,
                  case .sessionInfo(let info) = response.result else {
                continue
            }

            syncSessionMeta(info, modelContext: modelContext)
            break
        }
    }

    public func fetchRecentMessages(sessionId: String, beforeCreatedAt: Int64 = 0, pageSize: UInt32 = 100) async {
        guard let mqtt,
              let modelContainer else { return }

        let ctx = ModelContext(modelContainer)
        let descriptor = FetchDescriptor<Session>(
            predicate: #Predicate { $0.sessionId == sessionId }
        )
        guard let session = (try? ctx.fetch(descriptor))?.first else { return }
        guard let targetDeviceID = await rpcTargetDeviceID(for: session.primaryAgentId) else {
            return
        }

        var req = Teamclaw_FetchSessionMessagesRequest()
        req.sessionID = sessionId
        req.beforeCreatedAt = beforeCreatedAt
        req.pageSize = pageSize

        var rpcReq = Teamclaw_RpcRequest()
        rpcReq.requestID = String(UUID().uuidString.prefix(8)).lowercased()
        rpcReq.senderDeviceID = deviceId
        rpcReq.method = .fetchSessionMessages(req)

        let topic = MQTTTopics.deviceRpcRequest(teamID: teamId, deviceID: targetDeviceID)
        guard let data = try? rpcReq.serializedData() else { return }
        try? await mqtt.publish(topic: topic, payload: data, retain: false)

        let stream = mqtt.messages()
        let deadline = Date().addingTimeInterval(10)
        for await msg in stream {
            if Date() > deadline { break }
            guard msg.topic == MQTTTopics.deviceRpcResponse(teamID: teamId, deviceID: deviceId),
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

    /// Fetches the daemon's current in-memory peer set via FetchPeers RPC.
    /// Phase 2b replacement for the retained devicePeers topic subscription.
    /// Returns empty array on timeout or decode error — the retained topic
    /// semantics degraded the same way, and callers are idempotent.
    public func fetchPeers() async -> [Amux_PeerInfo] {
        guard let mqtt else { return [] }

        let fetch = Teamclaw_FetchPeersRequest()  // empty request

        var rpcReq = Teamclaw_RpcRequest()
        rpcReq.requestID = String(UUID().uuidString.prefix(8)).lowercased()
        rpcReq.senderDeviceID = deviceId
        rpcReq.method = .fetchPeers(fetch)

        let requestId = rpcReq.requestID
        let topic = MQTTTopics.deviceRpcRequest(teamID: teamId, deviceID: deviceId)
        let stream = mqtt.messages()

        guard let data = try? rpcReq.serializedData() else { return [] }
        try? await mqtt.publish(topic: topic, payload: data, retain: false)

        let deadline = Date().addingTimeInterval(10)
        for await msg in stream {
            if Date() > deadline { break }
            if msg.topic == MQTTTopics.deviceRpcResponse(teamID: teamId, deviceID: deviceId),
               let response = try? Teamclaw_RpcResponse(serializedBytes: msg.payload),
               response.requestID == requestId {
                if case let .fetchPeersResult(result)? = response.result {
                    return result.peers
                }
                return []
            }
        }
        return []
    }

    /// Fetches the daemon's workspace set via FetchWorkspaces RPC.
    /// Phase 2b replacement for the retained deviceWorkspaces topic subscription.
    public func fetchWorkspaces() async -> [Amux_WorkspaceInfo] {
        guard let mqtt else { return [] }

        let fetch = Teamclaw_FetchWorkspacesRequest()  // empty request

        var rpcReq = Teamclaw_RpcRequest()
        rpcReq.requestID = String(UUID().uuidString.prefix(8)).lowercased()
        rpcReq.senderDeviceID = deviceId
        rpcReq.method = .fetchWorkspaces(fetch)

        let requestId = rpcReq.requestID
        let topic = MQTTTopics.deviceRpcRequest(teamID: teamId, deviceID: deviceId)
        let stream = mqtt.messages()

        guard let data = try? rpcReq.serializedData() else { return [] }
        try? await mqtt.publish(topic: topic, payload: data, retain: false)

        let deadline = Date().addingTimeInterval(10)
        for await msg in stream {
            if Date() > deadline { break }
            if msg.topic == MQTTTopics.deviceRpcResponse(teamID: teamId, deviceID: deviceId),
               let response = try? Teamclaw_RpcResponse(serializedBytes: msg.payload),
               response.requestID == requestId {
                if case let .fetchWorkspacesResult(result)? = response.result {
                    return result.workspaces
                }
                return []
            }
        }
        return []
    }

    /// Adds a workspace via daemon RPC. Returns a `(success, error)` pair —
    /// daemon responds with `success=true, error=""` on accept; `success=false`
    /// with a daemon-side reason on reject. Returns `(false, "timeout")` when no
    /// response arrives within 10s.
    public func addWorkspaceRpc(path: String) async -> (Bool, String) {
        guard let mqtt else { return (false, "mqtt not configured") }

        var add = Teamclaw_AddWorkspaceRequest()
        add.path = path

        var rpcReq = Teamclaw_RpcRequest()
        rpcReq.requestID = String(UUID().uuidString.prefix(8)).lowercased()
        rpcReq.senderDeviceID = deviceId
        rpcReq.method = .addWorkspace(add)

        let requestId = rpcReq.requestID
        let topic = MQTTTopics.deviceRpcRequest(teamID: teamId, deviceID: deviceId)
        let stream = mqtt.messages()

        guard let data = try? rpcReq.serializedData() else {
            return (false, "encode failed")
        }
        do {
            try await mqtt.publish(topic: topic, payload: data, retain: false)
        } catch {
            return (false, "publish failed: \(error.localizedDescription)")
        }

        let deadline = Date().addingTimeInterval(10)
        for await msg in stream {
            if Date() > deadline { break }
            if msg.topic == MQTTTopics.deviceRpcResponse(teamID: teamId, deviceID: deviceId),
               let response = try? Teamclaw_RpcResponse(serializedBytes: msg.payload),
               response.requestID == requestId {
                return (response.success, response.error)
            }
        }
        return (false, "timeout")
    }

    /// Removes a workspace via daemon RPC. Same `(success, error)` semantics as
    /// `addWorkspaceRpc`.
    public func removeWorkspaceRpc(workspaceId: String) async -> (Bool, String) {
        guard let mqtt else { return (false, "mqtt not configured") }

        var remove = Teamclaw_RemoveWorkspaceRequest()
        remove.workspaceID = workspaceId

        var rpcReq = Teamclaw_RpcRequest()
        rpcReq.requestID = String(UUID().uuidString.prefix(8)).lowercased()
        rpcReq.senderDeviceID = deviceId
        rpcReq.method = .removeWorkspace(remove)

        let requestId = rpcReq.requestID
        let topic = MQTTTopics.deviceRpcRequest(teamID: teamId, deviceID: deviceId)
        let stream = mqtt.messages()

        guard let data = try? rpcReq.serializedData() else {
            return (false, "encode failed")
        }
        do {
            try await mqtt.publish(topic: topic, payload: data, retain: false)
        } catch {
            return (false, "publish failed: \(error.localizedDescription)")
        }

        let deadline = Date().addingTimeInterval(10)
        for await msg in stream {
            if Date() > deadline { break }
            if msg.topic == MQTTTopics.deviceRpcResponse(teamID: teamId, deviceID: deviceId),
               let response = try? Teamclaw_RpcResponse(serializedBytes: msg.payload),
               response.requestID == requestId {
                return (response.success, response.error)
            }
        }
        return (false, "timeout")
    }

    private func configureRuntime(
        mqtt: MQTTService,
        teamId: String,
        deviceId: String,
        peerId: String,
        modelContainer: ModelContainer
    ) {
        self.mqtt = mqtt
        self.teamId = teamId
        self.deviceId = deviceId
        self.peerId = peerId
        self.modelContainer = modelContainer
    }

    private func rpcTargetDeviceID(for primaryAgentId: String?) async -> String? {
        guard let primaryAgentId, !primaryAgentId.isEmpty else { return nil }
        guard let repository = try? SupabaseAgentAccessRepository() else { return nil }
        return try? await repository.deviceID(for: primaryAgentId)
    }

    private func rehydrateForegroundSessionSubscriptions(on mqtt: MQTTService) async {
        for sessionId in foregroundSessionIDsSet.sorted() {
            try? await mqtt.subscribe(MQTTTopics.sessionLive(teamID: teamId, sessionID: sessionId))
        }
    }

    internal func configureRuntimeForTesting(
        mqtt: MQTTService,
        teamId: String,
        deviceId: String,
        peerId: String,
        modelContainer: ModelContainer
    ) {
        configureRuntime(
            mqtt: mqtt,
            teamId: teamId,
            deviceId: deviceId,
            peerId: peerId,
            modelContainer: modelContainer
        )
        isTestingForegroundLifecycle = true
    }

    internal func handleIncomingForTesting(_ incoming: MQTTIncoming) async {
        guard let modelContainer else { return }
        await handleIncoming(incoming, modelContext: ModelContext(modelContainer))
    }

    /// Sets `localMemberId` directly for unit tests that need `sendMessage`
    /// to pass its actor-id guard without going through the FetchPeers RPC.
    internal func setLocalMemberIdForTesting(_ memberId: String) {
        localMemberId = memberId
    }

    private func fetchRecentMessagesForForegroundSession(_ sessionId: String) async {
        if isTestingForegroundLifecycle {
            fetchRecentMessagesCalls.append(sessionId)
            return
        }
        await fetchRecentMessages(sessionId: sessionId)
    }
}
