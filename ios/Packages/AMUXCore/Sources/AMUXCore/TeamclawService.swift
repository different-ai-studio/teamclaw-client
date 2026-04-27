import Foundation
import Observation
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
    private var peerId: String = ""
    private var connectedAgentsStore: ConnectedAgentsStore?
    /// Daemon device-ids whose `rpc/res` and `notify` topics are currently
    /// subscribed. Kept in sync with `connectedAgentsStore.agents` via the
    /// observer task that `start()` launches.
    private var subscribedDeviceIDs: Set<String> = []
    private var agentObserverTask: Task<Void, Never>?
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
        peerId: String,
        modelContext: ModelContext,
        connectedAgentsStore: ConnectedAgentsStore?
    ) {
        listenerTask?.cancel()
        agentObserverTask?.cancel()
        let container = modelContext.container
        configureRuntime(
            mqtt: mqtt,
            teamId: teamId,
            peerId: peerId,
            modelContainer: container,
            connectedAgentsStore: connectedAgentsStore
        )
        let ctx = ModelContext(container)

        // Load cached sessions immediately
        sessions = (try? ctx.fetch(FetchDescriptor<Session>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        ))) ?? []

        listenerTask = Task { [weak self] in
            guard let self else { return }
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

            // Per-daemon notify+rpcRes subscriptions. Re-synced on agents-store
            // mutations so newly-resolved daemons start receiving notify and
            // RPC responses without a manual reconnect.
            await self.resyncDaemonSubscriptions()
            await self.rehydrateForegroundSessionSubscriptions(on: mqtt)

            self.agentObserverTask = Task { [weak self] in
                guard let self else { return }
                while !Task.isCancelled {
                    await self.waitForAgentsMutation()
                    if Task.isCancelled { return }
                    await self.resyncDaemonSubscriptions()
                }
            }

            // Phase 2b: peers come from FetchPeers RPC instead of retained
            // devicePeers subscription. One-shot fetch after subscribe; notify
            // handler does follow-ups on peers.changed / members.changed.
            Task { [weak self] in
                guard let self else { return }
                let peers = await self.fetchPeersAcrossDaemons()
                self.syncPeers(peers)
            }

            self.isConnected = true
            print("[TeamclawService] subscribed to teamclaw topics for team: \(teamId)")

            for await incoming in stream {
                if Task.isCancelled { break }
                await self.handleIncoming(incoming, modelContext: ctx)
            }

            self.isConnected = false
        }
    }

    public func stop() {
        listenerTask?.cancel()
        listenerTask = nil
        agentObserverTask?.cancel()
        agentObserverTask = nil
        isConnected = false
        for sessionId in foregroundSessionIDsSet {
            let topic = MQTTTopics.sessionLive(teamID: teamId, sessionID: sessionId)
            mqtt?.unsubscribeForLifecycleStop(topic)
        }
        foregroundSessionIDsSet.removeAll()
        subscribedDeviceIDs.removeAll()
    }

    private func resyncDaemonSubscriptions() async {
        guard let mqtt else { return }
        let desired: Set<String> = {
            guard let store = connectedAgentsStore else { return [] }
            return Set(store.agents.compactMap(\.deviceID).filter { !$0.isEmpty })
        }()
        let toAdd = desired.subtracting(subscribedDeviceIDs)
        let toRemove = subscribedDeviceIDs.subtracting(desired)
        for id in toAdd {
            try? await mqtt.subscribe(MQTTTopics.deviceNotify(teamID: teamId, deviceID: id))
            try? await mqtt.subscribe(MQTTTopics.deviceRpcResponse(teamID: teamId, deviceID: id))
        }
        for id in toRemove {
            try? await mqtt.unsubscribe(MQTTTopics.deviceNotify(teamID: teamId, deviceID: id))
            try? await mqtt.unsubscribe(MQTTTopics.deviceRpcResponse(teamID: teamId, deviceID: id))
        }
        subscribedDeviceIDs = desired

        // FetchPeers needs at least one subscribed daemon to be able to issue
        // the RPC. The one-shot fetch in `start()` runs before
        // `connectedAgentsStore` populates, so it normally returns no peers
        // and `localMemberId` never resolves. Re-fetch whenever new daemons
        // come online so subsequent `sendMessage` calls can pass their actor
        // guard.
        if !toAdd.isEmpty {
            let peers = await fetchPeersAcrossDaemons()
            syncPeers(peers)
        }
    }

    private func waitForAgentsMutation() async {
        guard let store = connectedAgentsStore else {
            try? await Task.sleep(for: .seconds(60))
            return
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            withObservationTracking {
                _ = store.agents
            } onChange: {
                cont.resume()
            }
        }
    }

    /// Fans FetchPeers RPCs across every known daemon and concatenates the
    /// results. Pre-multi-daemon code only queried `self.deviceId`; we mirror
    /// the same intent (resolve our peer record for `localMemberId`) but no
    /// longer require a single privileged daemon. Returns an empty array if no
    /// daemons are subscribed yet.
    private func fetchPeersAcrossDaemons() async -> [Amux_PeerInfo] {
        var combined: [Amux_PeerInfo] = []
        for id in subscribedDeviceIDs.sorted() {
            combined.append(contentsOf: await fetchPeers(targetDeviceID: id))
        }
        return combined
    }

    // MARK: - Message Dispatch

    private func handleIncoming(_ incoming: MQTTIncoming, modelContext: ModelContext) async {
        let topic = incoming.topic

        if let notifyDeviceID = parseDeviceNotifyTopic(topic) {
            guard let notify = try? Teamclaw_Notify(serializedBytes: incoming.payload) else {
                print("[TeamclawService] failed to decode device/notify payload as Notify")
                return
            }

            switch notify.eventType {
            case "membership.refresh", "members.changed":
                if !notify.refreshHint.isEmpty {
                    await refreshSessionState(for: notify.refreshHint, modelContext: modelContext)
                }
            case "peers.changed":
                // Refresh peers from the daemon that emitted the notify, since
                // its peer set is the authority for joins/leaves in its scope.
                let peers = await fetchPeers(targetDeviceID: notifyDeviceID)
                syncPeers(peers)
            case "workspaces.changed":
                // Placeholder: Task 6 wires the returned array into state.
                _ = await fetchWorkspaces(targetDeviceID: notifyDeviceID)
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
                ideaId: proto.ideaID
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
        if !proto.ideaID.isEmpty { existing.ideaId = proto.ideaID }
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

        if envelope.eventType.hasPrefix("idea.") {
            guard let ideaEvent = try? Teamclaw_IdeaEvent(serializedBytes: envelope.body) else {
                print("[TeamclawService] failed to decode IdeaEvent from live event: \(envelope.eventType)")
                return
            }
            syncIdeaEvent(ideaEvent, modelContext: modelContext)
        }
    }

    private func syncIdeaEvent(_ event: Teamclaw_IdeaEvent, modelContext: ModelContext) {
        let idea: Teamclaw_Idea
        switch event.event {
        case .created(let item):
            idea = item
        case .updated(let item):
            idea = item
        case .claimed(let claim):
            let claimItemId = claim.ideaID
            let claimDesc = FetchDescriptor<SessionIdea>(
                predicate: #Predicate { $0.ideaId == claimItemId }
            )
            if let existing = (try? modelContext.fetch(claimDesc))?.first {
                if existing.status == "open" {
                    existing.status = "in_progress"
                    try? modelContext.save()
                }
            }
            return
        case .submitted(let sub):
            let subItemId = sub.ideaID
            let subDesc = FetchDescriptor<SessionIdea>(
                predicate: #Predicate { $0.ideaId == subItemId }
            )
            if let existing = (try? modelContext.fetch(subDesc))?.first {
                existing.status = "done"
                try? modelContext.save()
            }
            return
        case .none:
            return
        }

        let itemId = idea.ideaID
        let descriptor = FetchDescriptor<SessionIdea>(
            predicate: #Predicate { $0.ideaId == itemId }
        )

        let statusStr: String
        switch idea.status {
        case .open: statusStr = "open"
        case .inProgress: statusStr = "in_progress"
        case .done: statusStr = "done"
        default: statusStr = "open"
        }

        if let existing = (try? modelContext.fetch(descriptor))?.first {
            existing.title = idea.title
            existing.ideaDescription = idea.description_p
            existing.status = statusStr
            existing.parentIdeaId = idea.parentID
            existing.archived = idea.archived
            existing.workspaceId = idea.workspaceID
        } else {
            let item = SessionIdea(
                ideaId: idea.ideaID,
                sessionId: idea.sessionID,
                workspaceId: idea.workspaceID,
                title: idea.title,
                ideaDescription: idea.description_p,
                status: statusStr,
                parentIdeaId: idea.parentID,
                createdBy: idea.createdBy,
                createdAt: idea.createdAt > 0
                    ? Date(timeIntervalSince1970: TimeInterval(idea.createdAt))
                    : .now,
                archived: idea.archived
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
        ideaId: String = ""
    ) -> Teamclaw_CreateSessionRequest {
        var createReq = Teamclaw_CreateSessionRequest()
        createReq.sessionType = .collab
        createReq.teamID = teamId
        createReq.title = title
        createReq.summary = summary
        createReq.inviteActorIds = inviteActorIds
        if !ideaId.isEmpty {
            createReq.ideaID = ideaId
        }
        if let actorId = currentHumanActorId {
            createReq.senderActorID = actorId
        }
        return createReq
    }

    public func createIdea(targetDeviceID: String, description: String, workspaceId: String = "") async -> Bool {
        guard let mqtt else { return false }
        guard !targetDeviceID.isEmpty else { return false }

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

        var createReq = Teamclaw_CreateIdeaRequest()
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
        rpcReq.senderDeviceID = targetDeviceID
        rpcReq.method = .createIdea(createReq)

        let requestId = rpcReq.requestID
        let topic = MQTTTopics.deviceRpcRequest(teamID: teamId, deviceID: targetDeviceID)
        let resTopic = MQTTTopics.deviceRpcResponse(teamID: teamId, deviceID: targetDeviceID)
        let stream = mqtt.messages()

        guard let data = try? rpcReq.serializedData() else { return false }
        try? await mqtt.publish(topic: topic, payload: data, retain: false)

        let deadline = Date().addingTimeInterval(10)
        for await msg in stream {
            if Date() > deadline { break }
            if msg.topic == resTopic {
                if let response = try? Teamclaw_RpcResponse(serializedBytes: msg.payload),
                   response.requestID == requestId {
                    return response.success
                }
            }
        }
        return false
    }

    /// Toggles the archived flag on an idea. Sends an `UpdateIdea` RPC
    /// with only `archived` set (other fields left empty / sentinel).
    /// Does not wait for the RPC response — the authoritative state arrives
    /// via the `IdeaEvent.updated` broadcast and flows through
    /// `syncIdeaEvent`. The call site typically flips `archived` on the
    /// SwiftData model first for optimistic UI; if the RPC fails, the next
    /// broadcast will reinstate the prior value.
    public func archiveIdea(targetDeviceID: String, ideaId: String, sessionId: String, archived: Bool) async {
        guard let mqtt else { return }
        guard !targetDeviceID.isEmpty else { return }

        var update = Teamclaw_UpdateIdeaRequest()
        update.sessionID = sessionId
        update.ideaID = ideaId
        update.archived = archived   // SwiftProtobuf: setting also flips hasArchived=true

        var rpcReq = Teamclaw_RpcRequest()
        rpcReq.requestID = String(UUID().uuidString.prefix(8)).lowercased()
        rpcReq.senderDeviceID = targetDeviceID
        rpcReq.method = .updateIdea(update)

        let topic = MQTTTopics.deviceRpcRequest(teamID: teamId, deviceID: targetDeviceID)
        guard let data = try? rpcReq.serializedData() else { return }
        try? await mqtt.publish(topic: topic, payload: data, retain: false)
    }

    /// Updates an idea's status via `UpdateIdea` RPC. Mirrors
    /// `archiveIdea` — fire-and-forget; authoritative state arrives
    /// via `IdeaEvent.updated` broadcast and flows through
    /// `syncIdeaEvent`. The call site typically flips `status` on the
    /// SwiftData model first for optimistic UI; if the RPC fails, the next
    /// broadcast will reinstate the prior value.
    ///
    /// - Parameter status: one of `"open"`, `"in_progress"`, `"done"`.
    ///   Any other value is sent as `.unknown` (which SwiftProtobuf skips,
    ///   producing a no-op update on the daemon side).
    public func updateIdeaStatus(targetDeviceID: String, ideaId: String, sessionId: String, status: String) async {
        guard let mqtt else { return }
        guard !targetDeviceID.isEmpty else { return }

        var update = Teamclaw_UpdateIdeaRequest()
        update.sessionID = sessionId
        update.ideaID = ideaId
        update.status = protoStatus(from: status)

        var rpcReq = Teamclaw_RpcRequest()
        rpcReq.requestID = String(UUID().uuidString.prefix(8)).lowercased()
        rpcReq.senderDeviceID = targetDeviceID
        rpcReq.method = .updateIdea(update)

        let topic = MQTTTopics.deviceRpcRequest(teamID: teamId, deviceID: targetDeviceID)
        guard let data = try? rpcReq.serializedData() else { return }
        try? await mqtt.publish(topic: topic, payload: data, retain: false)
    }

    /// Patches any combination of title, description, and status on an idea.
    /// Title / description are sent as empty strings when `nil` is
    /// passed (SwiftProtobuf treats empty strings as "unset" on the
    /// daemon side). Status omitted when `nil`. Fire-and-forget.
    public func updateIdea(
        targetDeviceID: String,
        ideaId: String,
        sessionId: String,
        title: String? = nil,
        description: String? = nil,
        status: String? = nil
    ) async {
        guard let mqtt else { return }
        guard !targetDeviceID.isEmpty else { return }

        var update = Teamclaw_UpdateIdeaRequest()
        update.sessionID = sessionId
        update.ideaID = ideaId
        if let title { update.title = title }
        if let description { update.description_p = description }
        if let status { update.status = protoStatus(from: status) }

        var rpcReq = Teamclaw_RpcRequest()
        rpcReq.requestID = String(UUID().uuidString.prefix(8)).lowercased()
        rpcReq.senderDeviceID = targetDeviceID
        rpcReq.method = .updateIdea(update)

        let topic = MQTTTopics.deviceRpcRequest(teamID: teamId, deviceID: targetDeviceID)
        guard let data = try? rpcReq.serializedData() else { return }
        try? await mqtt.publish(topic: topic, payload: data, retain: false)
    }

    /// Maps the SwiftData `Idea.status` string domain to the protobuf
    /// `IdeaStatus` enum. Unknown inputs map to `.unknown` — defensive
    /// against future status values landing in the model before this mapper
    /// is updated.
    private func protoStatus(from status: String) -> Teamclaw_IdeaStatus {
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
        let resolvedDeviceID: String?
        if let cached = resolveDeviceID(forPrimaryAgentID: session.primaryAgentId) {
            resolvedDeviceID = cached
        } else {
            resolvedDeviceID = await rpcTargetDeviceID(for: session.primaryAgentId)
        }
        guard let targetDeviceID = resolvedDeviceID else {
            return
        }

        var req = Teamclaw_FetchSessionRequest()
        req.sessionID = sessionId

        var rpcReq = Teamclaw_RpcRequest()
        rpcReq.requestID = String(UUID().uuidString.prefix(8)).lowercased()
        rpcReq.senderDeviceID = targetDeviceID
        rpcReq.method = .fetchSession(req)

        let topic = MQTTTopics.deviceRpcRequest(teamID: teamId, deviceID: targetDeviceID)
        let resTopic = MQTTTopics.deviceRpcResponse(teamID: teamId, deviceID: targetDeviceID)
        guard let data = try? rpcReq.serializedData() else { return }
        try? await mqtt.publish(topic: topic, payload: data, retain: false)

        let stream = mqtt.messages()
        let deadline = Date().addingTimeInterval(10)
        for await msg in stream {
            if Date() > deadline { break }
            guard msg.topic == resTopic,
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
        let resolvedDeviceID: String?
        if let cached = resolveDeviceID(forPrimaryAgentID: session.primaryAgentId) {
            resolvedDeviceID = cached
        } else {
            resolvedDeviceID = await rpcTargetDeviceID(for: session.primaryAgentId)
        }
        guard let targetDeviceID = resolvedDeviceID else {
            return
        }

        var req = Teamclaw_FetchSessionMessagesRequest()
        req.sessionID = sessionId
        req.beforeCreatedAt = beforeCreatedAt
        req.pageSize = pageSize

        var rpcReq = Teamclaw_RpcRequest()
        rpcReq.requestID = String(UUID().uuidString.prefix(8)).lowercased()
        rpcReq.senderDeviceID = targetDeviceID
        rpcReq.method = .fetchSessionMessages(req)

        let topic = MQTTTopics.deviceRpcRequest(teamID: teamId, deviceID: targetDeviceID)
        let resTopic = MQTTTopics.deviceRpcResponse(teamID: teamId, deviceID: targetDeviceID)
        guard let data = try? rpcReq.serializedData() else { return }
        try? await mqtt.publish(topic: topic, payload: data, retain: false)

        let stream = mqtt.messages()
        let deadline = Date().addingTimeInterval(10)
        for await msg in stream {
            if Date() > deadline { break }
            guard msg.topic == resTopic,
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

    /// Fetches a single daemon's current in-memory peer set via FetchPeers
    /// RPC. Phase 2b replacement for the retained devicePeers topic subscription.
    /// Returns empty array on timeout or decode error — the retained topic
    /// semantics degraded the same way, and callers are idempotent.
    public func fetchPeers(targetDeviceID: String) async -> [Amux_PeerInfo] {
        guard let mqtt else { return [] }
        guard !targetDeviceID.isEmpty else { return [] }

        let fetch = Teamclaw_FetchPeersRequest()  // empty request

        var rpcReq = Teamclaw_RpcRequest()
        rpcReq.requestID = String(UUID().uuidString.prefix(8)).lowercased()
        rpcReq.senderDeviceID = targetDeviceID
        rpcReq.method = .fetchPeers(fetch)

        let requestId = rpcReq.requestID
        let topic = MQTTTopics.deviceRpcRequest(teamID: teamId, deviceID: targetDeviceID)
        let resTopic = MQTTTopics.deviceRpcResponse(teamID: teamId, deviceID: targetDeviceID)
        let stream = mqtt.messages()

        guard let data = try? rpcReq.serializedData() else { return [] }
        try? await mqtt.publish(topic: topic, payload: data, retain: false)

        let deadline = Date().addingTimeInterval(10)
        for await msg in stream {
            if Date() > deadline { break }
            if msg.topic == resTopic,
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

    /// Fetches a single daemon's workspace set via FetchWorkspaces RPC.
    /// Phase 2b replacement for the retained deviceWorkspaces topic subscription.
    public func fetchWorkspaces(targetDeviceID: String) async -> [Amux_WorkspaceInfo] {
        guard let mqtt else { return [] }
        guard !targetDeviceID.isEmpty else { return [] }

        let fetch = Teamclaw_FetchWorkspacesRequest()  // empty request

        var rpcReq = Teamclaw_RpcRequest()
        rpcReq.requestID = String(UUID().uuidString.prefix(8)).lowercased()
        rpcReq.senderDeviceID = targetDeviceID
        rpcReq.method = .fetchWorkspaces(fetch)

        let requestId = rpcReq.requestID
        let topic = MQTTTopics.deviceRpcRequest(teamID: teamId, deviceID: targetDeviceID)
        let resTopic = MQTTTopics.deviceRpcResponse(teamID: teamId, deviceID: targetDeviceID)
        let stream = mqtt.messages()

        guard let data = try? rpcReq.serializedData() else { return [] }
        try? await mqtt.publish(topic: topic, payload: data, retain: false)

        let deadline = Date().addingTimeInterval(10)
        for await msg in stream {
            if Date() > deadline { break }
            if msg.topic == resTopic,
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

    /// Convenience: fans `fetchWorkspaces` across every subscribed daemon and
    /// concatenates the results. Used by SessionListVM startup, which doesn't
    /// know which daemon owns which workspace yet.
    public func fetchWorkspaces() async -> [Amux_WorkspaceInfo] {
        var combined: [Amux_WorkspaceInfo] = []
        for id in subscribedDeviceIDs.sorted() {
            combined.append(contentsOf: await fetchWorkspaces(targetDeviceID: id))
        }
        return combined
    }

    /// Adds a workspace via daemon RPC. Returns a `(success, error)` pair —
    /// daemon responds with `success=true, error=""` on accept; `success=false`
    /// with a daemon-side reason on reject. Returns `(false, "timeout")` when no
    /// response arrives within 10s.
    public func addWorkspaceRpc(targetDeviceID: String, path: String) async -> (Bool, String) {
        guard let mqtt else { return (false, "mqtt not configured") }
        guard !targetDeviceID.isEmpty else { return (false, "no target device id") }

        var add = Teamclaw_AddWorkspaceRequest()
        add.path = path

        var rpcReq = Teamclaw_RpcRequest()
        rpcReq.requestID = String(UUID().uuidString.prefix(8)).lowercased()
        rpcReq.senderDeviceID = targetDeviceID
        rpcReq.method = .addWorkspace(add)

        let requestId = rpcReq.requestID
        let topic = MQTTTopics.deviceRpcRequest(teamID: teamId, deviceID: targetDeviceID)
        let resTopic = MQTTTopics.deviceRpcResponse(teamID: teamId, deviceID: targetDeviceID)
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
            if msg.topic == resTopic,
               let response = try? Teamclaw_RpcResponse(serializedBytes: msg.payload),
               response.requestID == requestId {
                return (response.success, response.error)
            }
        }
        return (false, "timeout")
    }

    /// Removes a workspace via daemon RPC. Same `(success, error)` semantics as
    /// `addWorkspaceRpc`.
    public func removeWorkspaceRpc(targetDeviceID: String, workspaceId: String) async -> (Bool, String) {
        guard let mqtt else { return (false, "mqtt not configured") }
        guard !targetDeviceID.isEmpty else { return (false, "no target device id") }

        var remove = Teamclaw_RemoveWorkspaceRequest()
        remove.workspaceID = workspaceId

        var rpcReq = Teamclaw_RpcRequest()
        rpcReq.requestID = String(UUID().uuidString.prefix(8)).lowercased()
        rpcReq.senderDeviceID = targetDeviceID
        rpcReq.method = .removeWorkspace(remove)

        let requestId = rpcReq.requestID
        let topic = MQTTTopics.deviceRpcRequest(teamID: teamId, deviceID: targetDeviceID)
        let resTopic = MQTTTopics.deviceRpcResponse(teamID: teamId, deviceID: targetDeviceID)
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
            if msg.topic == resTopic,
               let response = try? Teamclaw_RpcResponse(serializedBytes: msg.payload),
               response.requestID == requestId {
                return (response.success, response.error)
            }
        }
        return (false, "timeout")
    }

    /// Spawns a runtime via daemon RPC. The daemon returns synchronously after
    /// the Claude Code subprocess spawns (not after full ACP-ready) — full
    /// lifecycle progress arrives via the retained `runtime/{id}/state` topic
    /// that callers should already be subscribed to via SessionListViewModel.
    ///
    /// Per spec invariant, the new-session UI must not block on full daemon
    /// startup; this RPC is the synchronous accept gate, lifecycle telemetry is
    /// observed asynchronously.
    ///
    /// Returns `.accepted(runtimeID, sessionID)` or `.rejected(reason)`.
    /// Times out at 15s with `.rejected("timeout")`.
    public func runtimeStartRpc(
        targetDeviceID: String,
        agentType: Amux_AgentType,
        workspaceId: String,
        worktree: String,
        sessionId: String,
        initialPrompt: String
    ) async -> RuntimeStartOutcome {
        guard let mqtt else { return .rejected("mqtt not configured") }
        guard !targetDeviceID.isEmpty else { return .rejected("no target device id") }

        var start = Teamclaw_RuntimeStartRequest()
        start.agentType = agentType
        start.workspaceID = workspaceId
        start.worktree = worktree
        start.sessionID = sessionId
        start.initialPrompt = initialPrompt

        var rpcReq = Teamclaw_RpcRequest()
        rpcReq.requestID = String(UUID().uuidString.prefix(8)).lowercased()
        rpcReq.senderDeviceID = targetDeviceID
        rpcReq.method = .runtimeStart(start)

        let requestId = rpcReq.requestID
        let reqTopic = MQTTTopics.deviceRpcRequest(teamID: teamId, deviceID: targetDeviceID)
        let resTopic = MQTTTopics.deviceRpcResponse(teamID: teamId, deviceID: targetDeviceID)

        // If target daemon hasn't been folded into the standing per-agent
        // subscription set yet (e.g. ConnectedAgentsStore hasn't reloaded),
        // subscribe ad-hoc so the response isn't dropped.
        let needsTargetSubscribe = !subscribedDeviceIDs.contains(targetDeviceID)
        if needsTargetSubscribe {
            try? await mqtt.subscribe(resTopic)
        }
        let stream = mqtt.messages()

        guard let data = try? rpcReq.serializedData() else {
            if needsTargetSubscribe { try? await mqtt.unsubscribe(resTopic) }
            return .rejected("encode failed")
        }
        do {
            try await mqtt.publish(topic: reqTopic, payload: data, retain: false)
        } catch {
            if needsTargetSubscribe { try? await mqtt.unsubscribe(resTopic) }
            return .rejected("publish failed: \(error.localizedDescription)")
        }

        print("[runtimeStartRpc] published requestID=\(requestId) to \(reqTopic) (awaiting response on \(resTopic))")

        let deadline = Date().addingTimeInterval(15)
        defer {
            if needsTargetSubscribe {
                Task { try? await mqtt.unsubscribe(resTopic) }
            }
        }
        for await msg in stream {
            if Date() > deadline { break }
            guard msg.topic == resTopic else { continue }
            guard let response = try? Teamclaw_RpcResponse(serializedBytes: msg.payload) else {
                print("[runtimeStartRpc] failed to decode response on \(msg.topic)")
                continue
            }
            guard response.requestID == requestId else { continue }

            print("[runtimeStartRpc] matched response on \(msg.topic) success=\(response.success) error=\(response.error)")
            if case .runtimeStartResult(let result)? = response.result {
                if result.accepted {
                    return .accepted(runtimeID: result.runtimeID, sessionID: result.sessionID)
                } else {
                    let reason = result.rejectedReason.isEmpty
                        ? (response.error.isEmpty ? "rejected" : response.error)
                        : result.rejectedReason
                    return .rejected(reason)
                }
            }
            return .rejected(response.error.isEmpty ? "no result" : response.error)
        }
        print("[runtimeStartRpc] TIMEOUT waiting for response to requestID=\(requestId)")
        return .rejected("timeout")
    }

    public enum RuntimeStartOutcome: Sendable {
        case accepted(runtimeID: String, sessionID: String)
        case rejected(String)
    }

    private func configureRuntime(
        mqtt: MQTTService,
        teamId: String,
        peerId: String,
        modelContainer: ModelContainer,
        connectedAgentsStore: ConnectedAgentsStore?
    ) {
        self.mqtt = mqtt
        self.teamId = teamId
        self.peerId = peerId
        self.modelContainer = modelContainer
        self.connectedAgentsStore = connectedAgentsStore
    }

    /// Resolves `agents.device_id` for `primaryAgentId` against the in-memory
    /// `ConnectedAgentsStore`. Cheap fast path used before falling back to a
    /// fresh Supabase query (`rpcTargetDeviceID`).
    private func resolveDeviceID(forPrimaryAgentID primaryAgentId: String?) -> String? {
        guard let primaryAgentId, !primaryAgentId.isEmpty,
              let store = connectedAgentsStore,
              let agent = store.agents.first(where: { $0.id == primaryAgentId }),
              let id = agent.deviceID, !id.isEmpty else {
            return nil
        }
        return id
    }

    /// Returns the daemon device-id when `topic` matches
    /// `amux/{team}/device/{deviceID}/notify`. Nil otherwise.
    private func parseDeviceNotifyTopic(_ topic: String) -> String? {
        let parts = topic.split(separator: "/")
        guard parts.count == 5,
              parts[0] == "amux",
              parts[2] == "device",
              parts[4] == "notify" else { return nil }
        let normalizedTeam = MQTTTopics.normalizedTeamID(teamId)
        guard parts[1] == Substring(normalizedTeam) else { return nil }
        return String(parts[3])
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
        peerId: String,
        modelContainer: ModelContainer,
        connectedAgentsStore: ConnectedAgentsStore? = nil
    ) {
        configureRuntime(
            mqtt: mqtt,
            teamId: teamId,
            peerId: peerId,
            modelContainer: modelContainer,
            connectedAgentsStore: connectedAgentsStore
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
