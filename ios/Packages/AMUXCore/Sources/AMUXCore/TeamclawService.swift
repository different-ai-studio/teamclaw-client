import Foundation
import SwiftProtobuf
import SwiftData

@Observable
@MainActor
public final class TeamclawService {
    public var sessions: [CollabSession] = []
    public var isConnected = false

    private var mqtt: MQTTService?
    public var mqttRef: MQTTService? { mqtt }
    private var teamId: String = ""
    private var deviceId: String = ""
    private var peerId: String = ""
    /// Member id of the local actor, resolved from the retained PeerList on
    /// `amux/{deviceId}/peers` by matching our own peer_id. Populated once
    /// PeerList arrives; used as `sender_actor_id` on outgoing RPCs so the
    /// daemon records the creator as a member rather than a device.
    public private(set) var localMemberId: String = ""
    private var listenerTask: Task<Void, Never>?

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
        let ctx = ModelContext(container)

        // Load cached sessions immediately
        sessions = (try? ctx.fetch(FetchDescriptor<CollabSession>(
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
            try? await mqtt.subscribe("teamclaw/\(teamId)/sessions")
            try? await mqtt.subscribe("teamclaw/\(teamId)/members")
            try? await mqtt.subscribe("teamclaw/\(teamId)/user/\(peerId)/invites")
            try? await mqtt.subscribe("teamclaw/\(teamId)/rpc/\(deviceId)/+/res")
            try? await mqtt.subscribe("teamclaw/\(teamId)/workitems")
            // amux-side peer list — used to resolve our local member id.
            try? await mqtt.subscribe("amux/\(deviceId)/peers")

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
    }

    // MARK: - Message Dispatch

    private func handleIncoming(_ incoming: MQTTIncoming, modelContext: ModelContext) async {
        let topic = incoming.topic

        if topic == "amux/\(deviceId)/peers" {
            if let list = try? Amux_PeerList(serializedBytes: incoming.payload) {
                if let mine = list.peers.first(where: { $0.peerID == peerId }),
                   !mine.memberID.isEmpty {
                    localMemberId = mine.memberID
                }
            }
            return
        }

        if topic == "teamclaw/\(teamId)/sessions" {
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

        if topic == "teamclaw/\(teamId)/workitems" {
            guard let event = try? Teamclaw_WorkItemEvent(serializedBytes: incoming.payload) else {
                print("[TeamclawService] failed to decode WorkItemEvent from global topic")
                return
            }
            syncWorkItemEvent(event, modelContext: modelContext)
            return
        }

        if topic.contains("/session/") && topic.hasSuffix("/workitems") {
            guard let event = try? Teamclaw_WorkItemEvent(serializedBytes: incoming.payload) else {
                print("[TeamclawService] failed to decode WorkItemEvent from topic: \(topic)")
                return
            }
            syncWorkItemEvent(event, modelContext: modelContext)
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
            }
            return
        }
    }

    // MARK: - Sync Handlers

    private func syncSessionIndex(_ index: Teamclaw_SessionIndex, modelContext: ModelContext) {
        for entry in index.sessions {
            let id = entry.sessionID
            let descriptor = FetchDescriptor<CollabSession>(
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
                existing.sessionType = sessionTypeStr
            } else {
                let sessionTypeStr: String
                switch entry.sessionType {
                case .control: sessionTypeStr = "control"
                case .collab: sessionTypeStr = "collab"
                default: sessionTypeStr = "collab"
                }
                let session = CollabSession(
                    sessionId: entry.sessionID,
                    sessionType: sessionTypeStr,
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
        sessions = (try? modelContext.fetch(FetchDescriptor<CollabSession>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        ))) ?? []
    }

    private func syncSessionMeta(_ proto: Teamclaw_SessionInfo, modelContext: ModelContext) {
        let sessionId = proto.sessionID
        guard !sessionId.isEmpty else { return }

        let descriptor = FetchDescriptor<CollabSession>(
            predicate: #Predicate { $0.sessionId == sessionId }
        )
        guard let existing = (try? modelContext.fetch(descriptor))?.first else {
            // No local CollabSession yet — the SessionIndex sync path will create one
            // when the retained /sessions message arrives. Avoid speculative inserts
            // to prevent duplicates; syncSessionMeta will be re-triggered on the
            // next retained delivery or can be applied once the session exists.
            return
        }

        existing.primaryAgentId = proto.primaryAgentID.isEmpty ? nil : proto.primaryAgentID
        if !proto.title.isEmpty { existing.title = proto.title }
        if !proto.summary.isEmpty { existing.summary = proto.summary }
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
        try? modelContext.save()
    }

    private func handleInvite(_ invite: Teamclaw_Invite) {
        print("[TeamclawService] received invite for session: \(invite.sessionID)")
        guard let mqtt else { return }
        let sid = invite.sessionID
        subscribeToSession(sid)

        // Send JoinSessionRequest RPC to session host
        var participant = Teamclaw_Participant()
        participant.actorID = peerId
        participant.actorType = .human
        participant.displayName = peerId
        participant.joinedAt = Int64(Date().timeIntervalSince1970)

        var joinReq = Teamclaw_JoinSessionRequest()
        joinReq.sessionID = sid
        joinReq.participant = participant

        var rpcReq = Teamclaw_RpcRequest()
        rpcReq.requestID = String(UUID().uuidString.prefix(8).lowercased())
        rpcReq.senderDeviceID = deviceId
        rpcReq.method = .joinSession(joinReq)

        let topic = "teamclaw/\(teamId)/rpc/\(invite.hostDeviceID)/\(rpcReq.requestID)/req"
        if let data = try? rpcReq.serializedData() {
            Task {
                try? await mqtt.publish(topic: topic, payload: data, retain: false)
            }
        }
    }

    private func syncWorkItemEvent(_ event: Teamclaw_WorkItemEvent, modelContext: ModelContext) {
        let workItem: Teamclaw_WorkItem
        switch event.event {
        case .created(let item):
            workItem = item
        case .updated(let item):
            workItem = item
        case .claimed(let claim):
            // Update work item status to in_progress on claim
            let claimItemId = claim.workItemID
            let claimDesc = FetchDescriptor<WorkItem>(
                predicate: #Predicate { $0.workItemId == claimItemId }
            )
            if let existing = (try? modelContext.fetch(claimDesc))?.first {
                if existing.status == "open" {
                    existing.status = "in_progress"
                    try? modelContext.save()
                }
            }
            return
        case .submitted(let sub):
            // Mark work item as done when submission received
            let subItemId = sub.workItemID
            let subDesc = FetchDescriptor<WorkItem>(
                predicate: #Predicate { $0.workItemId == subItemId }
            )
            if let existing = (try? modelContext.fetch(subDesc))?.first {
                existing.status = "done"
                try? modelContext.save()
            }
            return
        case .none:
            return
        }

        let itemId = workItem.workItemID
        let descriptor = FetchDescriptor<WorkItem>(
            predicate: #Predicate { $0.workItemId == itemId }
        )

        let statusStr: String
        switch workItem.status {
        case .open: statusStr = "open"
        case .inProgress: statusStr = "in_progress"
        case .done: statusStr = "done"
        default: statusStr = "open"
        }

        if let existing = (try? modelContext.fetch(descriptor))?.first {
            existing.title = workItem.title
            existing.itemDescription = workItem.description_p
            existing.status = statusStr
            existing.parentId = workItem.parentID
            existing.archived = workItem.archived
        } else {
            let item = WorkItem(
                workItemId: workItem.workItemID,
                sessionId: workItem.sessionID,
                title: workItem.title,
                itemDescription: workItem.description_p,
                status: statusStr,
                parentId: workItem.parentID,
                createdBy: workItem.createdBy,
                createdAt: workItem.createdAt > 0
                    ? Date(timeIntervalSince1970: TimeInterval(workItem.createdAt))
                    : .now,
                archived: workItem.archived
            )
            modelContext.insert(item)
        }
        try? modelContext.save()
    }

    // MARK: - Outbound

    /// Send a text message to a collab session.
    ///
    /// - Parameter modelId: Optional model identifier the user picked in the composer.
    ///   Forwarded via ``Teamclaw_Message/model`` and proxied to the agent's session by
    ///   the daemon's collab→agent dispatch path, which calls `send_set_model` before
    ///   `send_prompt` when the model differs from the agent's current model.
    public func sendMessage(sessionId: String, content: String, actorId: String, modelId: String? = nil) {
        guard let mqtt else { return }
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

        let topic = "teamclaw/\(teamId)/session/\(sessionId)/messages"
        Task {
            try? await mqtt.publish(topic: topic, payload: data, retain: false)
        }
    }

    public func createWorkItem(description: String) async -> Bool {
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

        var createReq = Teamclaw_CreateWorkItemRequest()
        createReq.sessionID = ""
        createReq.title = title
        createReq.description_p = description
        createReq.senderActorID = localMemberId

        var rpcReq = Teamclaw_RpcRequest()
        rpcReq.requestID = String(UUID().uuidString.prefix(8)).lowercased()
        rpcReq.senderDeviceID = deviceId
        rpcReq.method = .createWorkItem(createReq)

        let requestId = rpcReq.requestID
        let topic = "teamclaw/\(teamId)/rpc/\(deviceId)/\(requestId)/req"

        guard let data = try? rpcReq.serializedData() else { return false }
        try? await mqtt.publish(topic: topic, payload: data, retain: false)

        let stream = mqtt.messages()
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

    /// Toggles the archived flag on a work item. Sends an `UpdateWorkItem` RPC
    /// with only `archived` set (other fields left empty / sentinel).
    /// Does not wait for the RPC response — the authoritative state arrives
    /// via the `WorkItemEvent.updated` broadcast and flows through
    /// `syncWorkItemEvent`. The call site typically flips `archived` on the
    /// SwiftData model first for optimistic UI; if the RPC fails, the next
    /// broadcast will reinstate the prior value.
    public func archiveWorkItem(workItemId: String, sessionId: String, archived: Bool) async {
        guard let mqtt else { return }

        var update = Teamclaw_UpdateWorkItemRequest()
        update.sessionID = sessionId
        update.workItemID = workItemId
        update.archived = archived   // SwiftProtobuf: setting also flips hasArchived=true

        var rpcReq = Teamclaw_RpcRequest()
        rpcReq.requestID = String(UUID().uuidString.prefix(8)).lowercased()
        rpcReq.senderDeviceID = deviceId
        rpcReq.method = .updateWorkItem(update)

        let topic = "teamclaw/\(teamId)/rpc/\(deviceId)/\(rpcReq.requestID)/req"
        guard let data = try? rpcReq.serializedData() else { return }
        try? await mqtt.publish(topic: topic, payload: data, retain: false)
    }

    /// Updates a work item's status via `UpdateWorkItem` RPC. Mirrors
    /// `archiveWorkItem` — fire-and-forget; authoritative state arrives
    /// via `WorkItemEvent.updated` broadcast and flows through
    /// `syncWorkItemEvent`. The call site typically flips `status` on the
    /// SwiftData model first for optimistic UI; if the RPC fails, the next
    /// broadcast will reinstate the prior value.
    ///
    /// - Parameter status: one of `"open"`, `"in_progress"`, `"done"`.
    ///   Any other value is sent as `.unknown` (which SwiftProtobuf skips,
    ///   producing a no-op update on the daemon side).
    public func updateWorkItemStatus(workItemId: String, sessionId: String, status: String) async {
        guard let mqtt else { return }

        var update = Teamclaw_UpdateWorkItemRequest()
        update.sessionID = sessionId
        update.workItemID = workItemId
        update.status = protoStatus(from: status)

        var rpcReq = Teamclaw_RpcRequest()
        rpcReq.requestID = String(UUID().uuidString.prefix(8)).lowercased()
        rpcReq.senderDeviceID = deviceId
        rpcReq.method = .updateWorkItem(update)

        let topic = "teamclaw/\(teamId)/rpc/\(deviceId)/\(rpcReq.requestID)/req"
        guard let data = try? rpcReq.serializedData() else { return }
        try? await mqtt.publish(topic: topic, payload: data, retain: false)
    }

    /// Patches any combination of title, description, and status on a work
    /// item. Title / description are sent as empty strings when `nil` is
    /// passed (SwiftProtobuf treats empty strings as "unset" on the
    /// daemon side). Status omitted when `nil`. Fire-and-forget.
    public func updateWorkItem(
        workItemId: String,
        sessionId: String,
        title: String? = nil,
        description: String? = nil,
        status: String? = nil
    ) async {
        guard let mqtt else { return }

        var update = Teamclaw_UpdateWorkItemRequest()
        update.sessionID = sessionId
        update.workItemID = workItemId
        if let title { update.title = title }
        if let description { update.description_p = description }
        if let status { update.status = protoStatus(from: status) }

        var rpcReq = Teamclaw_RpcRequest()
        rpcReq.requestID = String(UUID().uuidString.prefix(8)).lowercased()
        rpcReq.senderDeviceID = deviceId
        rpcReq.method = .updateWorkItem(update)

        let topic = "teamclaw/\(teamId)/rpc/\(deviceId)/\(rpcReq.requestID)/req"
        guard let data = try? rpcReq.serializedData() else { return }
        try? await mqtt.publish(topic: topic, payload: data, retain: false)
    }

    /// Maps the SwiftData `WorkItem.status` string domain to the protobuf
    /// `WorkItemStatus` enum. Unknown inputs map to `.unknown` — defensive
    /// against future status values landing in the model before this mapper
    /// is updated.
    private func protoStatus(from status: String) -> Teamclaw_WorkItemStatus {
        switch status {
        case "open": return .open
        case "in_progress": return .inProgress
        case "done": return .done
        default: return .unknown
        }
    }

    public func subscribeToSession(_ sessionId: String) {
        guard let mqtt else { return }
        let base = "teamclaw/\(teamId)/session/\(sessionId)"
        Task {
            try? await mqtt.subscribe("\(base)/messages")
            try? await mqtt.subscribe("\(base)/meta")
            try? await mqtt.subscribe("\(base)/workitems")
            try? await mqtt.subscribe("\(base)/presence")
        }
    }
}
