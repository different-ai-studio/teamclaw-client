import Foundation
import Observation
import SwiftData

public struct SlashCommand: Identifiable, Equatable, Hashable, Sendable {
    public let name: String
    public let description: String
    public let inputHint: String   // "" = no input required
    public var id: String { name }

    public init(name: String, description: String, inputHint: String) {
        self.name = name
        self.description = description
        self.inputHint = inputHint
    }
}

@Observable @MainActor
public final class RuntimeDetailViewModel {
    public var events: [AgentEvent] = []
    /// Slash commands announced by the attached runtime via
    /// ACP `AvailableCommandsUpdate`. Replaced wholesale on each push.
    /// In-memory only — not persisted to SwiftData.
    public var availableCommands: [SlashCommand] = []
    /// Memoised tool-run grouping over `events`. Views should iterate this
    /// instead of calling `groupEvents(vm.events)` in body, which previously
    /// made grouping O(n) on every streaming delta frame. Recomputed by
    /// `recomputeGroups()` at each mutation site.
    public private(set) var groupedEvents: [GroupedEvent] = []
    public var isStreaming = false
    public var streamingText = ""
    /// Mirrors the model id stamped by the daemon on streaming output deltas
    /// so the synthesized event in stop()/idle flush carries the model too.
    private var streamingModel: String?
    public var isDaemonOnline = true
    public var runtime: Runtime?
    public let session: Session?
    private let mqtt: MQTTService
    private let teamID: String
    private let peerId: String
    private let teamclawService: TeamclawService?
    private let connectedAgentsStore: ConnectedAgentsStore?
    private var task: Task<Void, Never>?

    // Expose for child views that need to pass these along
    public var mqttRef: MQTTService { mqtt }
    public var peerIdRef: String { peerId }
    /// Daemon device-id resolved from session/runtime context. Empty when
    /// no daemon mapping is available yet (e.g. ConnectedAgentsStore still
    /// loading and runtime row hasn't received state). Callers that need it
    /// for an MQTT publish should bail when empty.
    public var daemonDeviceIdRef: String { resolveDaemonDeviceId() }

    public var sessionTitle: String {
        if let runtime, !runtime.sessionTitle.isEmpty { return runtime.sessionTitle }
        if let runtime {
            let wt = runtime.worktree
            if !wt.isEmpty {
                let last = wt.split(separator: "/").last.map(String.init) ?? wt
                if last != "." { return last }
            }
            return runtime.runtimeId
        }
        if let session, !session.title.isEmpty { return session.title }
        return "Session"
    }

    public var isActive: Bool { runtime?.isActive ?? false }
    public var isIdle: Bool { runtime?.isIdle ?? true }
    public var participantCount: Int { session?.participantCount ?? 0 }
    public var hasRuntime: Bool { runtime != nil }

    /// Bucket key for AgentEvent storage. Multiple sessions sharing a single
    /// daemon agent identity (Runtime.runtimeId == daemon's Supabase actor_id
    /// — see resolveRuntime) would otherwise collide their event histories
    /// under one shared agentId, leaking session N-1's prompts/replies into
    /// session N's view. When a session is in scope we key by session_id;
    /// the legacy runtime-only path (no session) keeps using runtime.runtimeId.
    private var eventScopeKey: String {
        if let session, !session.sessionId.isEmpty { return session.sessionId }
        return runtime?.runtimeId ?? ""
    }

    public init(runtime: Runtime?,
                mqtt: MQTTService,
                teamID: String = "",
                peerId: String,
                session: Session? = nil,
                teamclawService: TeamclawService? = nil,
                connectedAgentsStore: ConnectedAgentsStore? = nil) {
        self.runtime = runtime; self.mqtt = mqtt; self.teamID = teamID; self.peerId = peerId
        self.session = session; self.teamclawService = teamclawService
        self.connectedAgentsStore = connectedAgentsStore
    }

    /// Resolves the daemon's MQTT device-id for the current runtime/session.
    /// Preference order:
    ///   1. ConnectedAgentsStore lookup keyed by `session.primaryAgentId` —
    ///      authoritative when the session is iOS-Supabase-created.
    ///   2. The runtime row's stored `daemonDeviceId` (populated by
    ///      SessionListVM from the topic path it received the state on).
    /// Returns an empty string when no daemon mapping is known yet — callers
    /// should treat that as "skip publish, retry later".
    private func resolveDaemonDeviceId() -> String {
        if let primary = session?.primaryAgentId,
           !primary.isEmpty,
           let agent = connectedAgentsStore?.agents.first(where: { $0.id == primary }),
           let id = agent.deviceID, !id.isEmpty {
            return id
        }
        if let runtime, !runtime.daemonDeviceId.isEmpty {
            return runtime.daemonDeviceId
        }
        return ""
    }

    private func resolveRuntime(modelContext: ModelContext) -> Runtime? {
        if let runtime {
            return runtime
        }
        guard let primaryAgentId = session?.primaryAgentId, !primaryAgentId.isEmpty else {
            return nil
        }
        let descriptor = FetchDescriptor<Runtime>(
            predicate: #Predicate { $0.runtimeId == primaryAgentId }
        )
        let resolved = (try? modelContext.fetch(descriptor))?.first
        if let resolved {
            runtime = resolved
        } else if let session {
            let placeholder = Runtime(runtimeId: primaryAgentId, status: 1)
            placeholder.sessionTitle = session.title
            placeholder.currentPrompt = session.summary
            runtime = placeholder
        }
        return runtime
    }

    /// Rebuilds `groupedEvents` from `events`. Call after any mutation that
    /// adds, removes, or reorders events, or changes the grouping-relevant
    /// fields on an existing event (eventType, isComplete, toolId).
    private func recomputeGroups() {
        groupedEvents = groupEvents(events)
    }

    // MARK: - Index caches (for O(1) event lookup during streaming)
    //
    // Long sessions accumulate thousands of events. Each tool_result /
    // permission_resolved / tool_title_update previously did a
    // `lastIndex(where:)` scan, making the event-handling hot path O(n)
    // and the full session O(n²). These maps + optionals give O(1) lookup;
    // they're maintained incrementally by `appendEvent`/`removeEvent` and
    // rebuilt after bulk operations (fetch, sort, insert-at-zero).
    private var toolUseIndexByToolId: [String: Int] = [:]
    private var permissionIndexByRequestId: [String: Int] = [:]
    private var todoUpdateIndex: Int?
    private var lastIncompleteOutputIndex: Int?

    private func rebuildIndexes() {
        toolUseIndexByToolId.removeAll(keepingCapacity: true)
        permissionIndexByRequestId.removeAll(keepingCapacity: true)
        todoUpdateIndex = nil
        lastIncompleteOutputIndex = nil
        for (i, e) in events.enumerated() { registerIndex(event: e, at: i) }
    }

    private func registerIndex(event: AgentEvent, at idx: Int) {
        switch event.eventType {
        case "tool_use":
            if let id = event.toolId { toolUseIndexByToolId[id] = idx }
        case "permission_request":
            if let id = event.toolId { permissionIndexByRequestId[id] = idx }
        case "todo_update":
            todoUpdateIndex = idx
        case "output":
            if !event.isComplete { lastIncompleteOutputIndex = idx }
        default:
            break
        }
    }

    private func appendEvent(_ event: AgentEvent) {
        let idx = events.count
        events.append(event)
        registerIndex(event: event, at: idx)
    }

    private func removeEvent(at idx: Int) {
        let removed = events.remove(at: idx)
        switch removed.eventType {
        case "tool_use":
            if let id = removed.toolId, toolUseIndexByToolId[id] == idx {
                toolUseIndexByToolId.removeValue(forKey: id)
            }
        case "permission_request":
            if let id = removed.toolId, permissionIndexByRequestId[id] == idx {
                permissionIndexByRequestId.removeValue(forKey: id)
            }
        case "todo_update":
            if todoUpdateIndex == idx { todoUpdateIndex = nil }
        case "output":
            if lastIncompleteOutputIndex == idx { lastIncompleteOutputIndex = nil }
        default: break
        }
        // Shift indexes that pointed past the removed position. k is tiny
        // in practice (one output, one todo, a handful of permissions,
        // tool count per session), so this stays well below the old
        // lastIndex(where:) cost over the whole event stream.
        for (k, v) in toolUseIndexByToolId where v > idx {
            toolUseIndexByToolId[k] = v - 1
        }
        for (k, v) in permissionIndexByRequestId where v > idx {
            permissionIndexByRequestId[k] = v - 1
        }
        if let t = todoUpdateIndex, t > idx { todoUpdateIndex = t - 1 }
        if let l = lastIncompleteOutputIndex, l > idx { lastIncompleteOutputIndex = l - 1 }
    }

    /// Validated O(1) lookup. Returns nil (and clears the stale cache
    /// entry) if the cached index no longer matches the predicate, so
    /// callers fall through to their "create new" branch as before.
    private func toolUseIndex(forToolId id: String) -> Int? {
        if let idx = toolUseIndexByToolId[id],
           idx < events.count,
           events[idx].eventType == "tool_use",
           events[idx].toolId == id {
            return idx
        }
        toolUseIndexByToolId.removeValue(forKey: id)
        return nil
    }

    private func permissionIndex(forRequestId id: String) -> Int? {
        if let idx = permissionIndexByRequestId[id],
           idx < events.count,
           events[idx].eventType == "permission_request",
           events[idx].toolId == id {
            return idx
        }
        permissionIndexByRequestId.removeValue(forKey: id)
        return nil
    }

    private func incompleteOutputIndex() -> Int? {
        if let idx = lastIncompleteOutputIndex,
           idx < events.count,
           events[idx].eventType == "output",
           events[idx].isComplete == false {
            return idx
        }
        lastIncompleteOutputIndex = nil
        return nil
    }

    public func start(modelContext: ModelContext) {
        task?.cancel()
        startModelContext = modelContext

        guard let runtime = resolveRuntime(modelContext: modelContext) else {
            // No runtime — collab-only session, nothing to subscribe to yet
            return
        }

        // Clear unread badge when user opens the session
        runtime.hasUnread = false
        try? modelContext.save()

        // Load cached events immediately (works offline)
        let runtimeId = runtime.runtimeId
        let scope = eventScopeKey
        let descriptor = FetchDescriptor<AgentEvent>(
            predicate: #Predicate { $0.agentId == scope },
            sortBy: [SortDescriptor(\.sequence)]
        )
        events = (try? modelContext.fetch(descriptor)) ?? []
        rebuildIndexes()

        // Insert initial prompt as first user bubble if not already present
        let initialPrompt = if let session, !session.summary.isEmpty {
            session.summary
        } else if !runtime.currentPrompt.isEmpty {
            runtime.currentPrompt
        } else {
            ""
        }

        if !initialPrompt.isEmpty && !events.contains(where: { $0.eventType == "user_prompt" }) {
            let promptEvent = AgentEvent(agentId: scope, sequence: 0, eventType: "user_prompt")
            promptEvent.text = initialPrompt
            modelContext.insert(promptEvent)
            events.insert(promptEvent, at: 0)
            // insert-at-zero shifts every cached index; cheaper to rebuild
            rebuildIndexes()
        }

        // Resume streaming state if there's an incomplete output event (saved by stop()).
        // Hydrate streamingText for an instant preview, then drop the synthetic
        // event — keeping it would render the same bytes as both a bubble and
        // the streaming text, and live deltas appended to streamingText would
        // visibly duplicate the bubble content. The incremental sync below
        // rebuilds streamingText from the daemon's raw deltas.
        if let idx = incompleteOutputIndex() {
            let lastOutput = events[idx]
            streamingText = lastOutput.text ?? ""
            streamingModel = lastOutput.model
            isStreaming = runtime.isActive
            modelContext.delete(lastOutput)
            removeEvent(at: idx)
        }

        recomputeGroups()

        // Two subscription paths:
        //   - Session-backed (the modern flow): subscribe to
        //     `amux/{team}/session/{sid}/live` and decode `Amux_Envelope` out
        //     of LiveEventEnvelope bodies tagged `event_type = "acp.event"`.
        //     iOS owns the session_id so this avoids the deviceId/runtimeId
        //     resolution dance that the legacy runtime/{r}/events path needed.
        //   - Runtime-only (legacy fallback): subscribe to
        //     `runtime/{r}/events` directly and decode raw envelopes. This
        //     path stays for now because IdeasTab/SessionsTab still create
        //     RuntimeDetailView from a Runtime row without a Session.
        let sessionLiveTopic: String? = session.map {
            MQTTTopics.sessionLive(teamID: teamID, sessionID: $0.sessionId)
        }
        let resolvedDeviceId = resolveDaemonDeviceId()
        let runtimeEventsTopic = MQTTTopics.runtimeEvents(teamID: teamID, deviceID: resolvedDeviceId, runtimeID: runtimeId)
        let subscribeTopic = sessionLiveTopic ?? runtimeEventsTopic
        task = Task {
            // Outer loop: each iteration represents a fresh MQTT connection lifecycle.
            // When the inner stream finishes (e.g. after disconnect clears continuations),
            // we loop back, wait for reconnect, resubscribe, and trigger an incremental
            // sync to fetch any events missed during the gap.
            while !Task.isCancelled {
                // Wait for MQTT to be connected
                while mqtt.connectionState != .connected {
                    try? await Task.sleep(for: .milliseconds(200))
                    if Task.isCancelled { return }
                }

                let stream = mqtt.messages()
                try? await mqtt.subscribe(subscribeTopic)
                print("[RuntimeDetailVM] subscribed to \(subscribeTopic)")

                // Pull any events we missed while disconnected (no-op on first
                // connect if local cache is empty and daemon has nothing newer).
                try? await requestIncrementalSync(modelContext: modelContext)

                for await msg in stream {
                    guard msg.topic == subscribeTopic else { continue }
                    let envelope: Amux_Envelope?
                    if sessionLiveTopic != nil {
                        guard let live = try? Teamclaw_LiveEventEnvelope(serializedBytes: msg.payload),
                              live.eventType == "acp.event" else { continue }
                        envelope = try? Amux_Envelope(serializedBytes: live.body)
                    } else {
                        envelope = try? Amux_Envelope(serializedBytes: msg.payload)
                    }
                    guard let envelope else { continue }
                    handleEnvelope(envelope, modelContext: modelContext)
                }
                // Stream finished — connection likely dropped. Loop and resubscribe.
                if Task.isCancelled { return }
                print("[RuntimeDetailVM] stream ended, waiting to resubscribe…")
            }
        }
    }

    public func stop() {
        task?.cancel(); task = nil

        // Flush any in-progress streaming text to a persisted event
        // so it's visible when the user returns
        if isStreaming, !streamingText.isEmpty, runtime != nil, let ctx = startModelContext {
            let seq = (events.last?.sequence ?? 0) + 1
            let event = AgentEvent(agentId: eventScopeKey, sequence: seq, eventType: "output")
            event.text = streamingText
            event.isComplete = false
            event.model = streamingModel
            ctx.insert(event)
            appendEvent(event)
            try? ctx.save()
            isStreaming = false
            streamingText = ""
            streamingModel = nil
            recomputeGroups()
        }
        startModelContext = nil
    }

    private func handleEnvelope(_ env: Amux_Envelope, modelContext: ModelContext) {
        switch env.payload {
        case .acpEvent(let acp):
            if handleAcpEvent(acp, sequence: Int(env.sequence), modelContext: modelContext) {
                try? modelContext.save()
                recomputeGroups()
            }
        case .collabEvent(let collab): handleCollabEvent(collab, sequence: Int(env.sequence))
        case .none: break
        }
    }

    /// Applies one ACP event to in-memory + SwiftData state. Returns `true`
    /// iff the event caused a SwiftData mutation or a change to grouping-
    /// relevant fields; callers save + recompute groups only when `true`.
    /// Streaming deltas (the hot path, dozens per second) return `false`
    /// after the first delta of a stream, skipping the SQLite commit and
    /// the O(n) regroup that would otherwise fire on every token.
    @discardableResult
    private func handleAcpEvent(_ acp: Amux_AcpEvent, sequence: Int, modelContext: ModelContext) -> Bool {
        // Daemon stamps `acp.model` on agent-reply events (output + thinking).
        // Mirror it onto the SwiftData event so the bubble can show the model
        // that produced it. Empty string from proto means "not stamped".
        let modelStamp: String? = acp.model.isEmpty ? nil : acp.model
        var dirty = false
        switch acp.event {
        case .output(let o):
            if o.isComplete {
                isStreaming = false
                if let idx = incompleteOutputIndex() {
                    events[idx].text = o.text
                    events[idx].isComplete = true
                    if let modelStamp { events[idx].model = modelStamp }
                    lastIncompleteOutputIndex = nil
                } else {
                    let event = AgentEvent(agentId: eventScopeKey, sequence: sequence, eventType: "output")
                    event.text = o.text; event.isComplete = true
                    event.model = modelStamp
                    modelContext.insert(event); appendEvent(event)
                }
                streamingText = ""
                streamingModel = nil
                dirty = true
            } else {
                // Streaming delta — only the first delta of a stream mutates
                // SwiftData (to drop the stop()-saved synthetic event).
                // Subsequent deltas update streamingText only; no save needed.
                if !isStreaming {
                    if let idx = incompleteOutputIndex() {
                        streamingText = events[idx].text ?? ""
                        modelContext.delete(events[idx])
                        removeEvent(at: idx)
                        dirty = true
                    }
                }
                isStreaming = true; streamingText += o.text
                if let modelStamp { streamingModel = modelStamp }
            }
        case .thinking(let t):
            if let last = events.last, last.eventType == "thinking" {
                last.text = (last.text ?? "") + t.text
                if let modelStamp { last.model = modelStamp }
            } else {
                let event = AgentEvent(agentId: eventScopeKey, sequence: sequence, eventType: "thinking")
                event.text = t.text
                event.model = modelStamp
                modelContext.insert(event); appendEvent(event)
            }
            dirty = true
        case .toolUse(let tu):
            let event = AgentEvent(agentId: eventScopeKey, sequence: sequence, eventType: "tool_use")
            event.toolName = tu.toolName; event.toolId = tu.toolID; event.text = tu.description_p
            modelContext.insert(event); appendEvent(event)
            dirty = true
        case .toolResult(let tr):
            if let idx = toolUseIndex(forToolId: tr.toolID) {
                events[idx].success = tr.success
                events[idx].isComplete = true
            } else {
                let event = AgentEvent(agentId: eventScopeKey, sequence: sequence, eventType: "tool_result")
                event.toolId = tr.toolID; event.success = tr.success; event.text = tr.summary
                modelContext.insert(event); appendEvent(event)
            }
            dirty = true
        case .error(let e):
            let event = AgentEvent(agentId: eventScopeKey, sequence: sequence, eventType: "error")
            event.text = e.message; modelContext.insert(event); appendEvent(event)
            dirty = true
        case .permissionRequest(let pr):
            let event = AgentEvent(agentId: eventScopeKey, sequence: sequence, eventType: "permission_request")
            event.toolName = pr.toolName; event.toolId = pr.requestID; event.text = pr.description_p
            modelContext.insert(event); appendEvent(event)
            dirty = true
        case .todoUpdate(let tu):
            // Daemon sends a full snapshot of todos each time. Update the
            // single existing todo_update event in-place instead of removing+
            // re-inserting — that used to leak SwiftData rows on every tick
            // (events.removeAll didn't delete from the store).
            let lines = tu.items.map { item -> String in
                let icon = item.status == .completed ? "done" : item.status == .inProgress ? "wip" : "todo"
                return "[\(icon)] \(item.content)"
            }
            let text = lines.joined(separator: "\n")
            if let idx = todoUpdateIndex, idx < events.count, events[idx].eventType == "todo_update" {
                events[idx].text = text
            } else {
                let event = AgentEvent(agentId: eventScopeKey, sequence: sequence, eventType: "todo_update")
                event.text = text
                modelContext.insert(event); appendEvent(event)
            }
            dirty = true
        case .statusChange(let sc):
            runtime?.status = Int(sc.newStatus.rawValue)
            dirty = true
            if sc.newStatus == .idle {
                if isStreaming && !streamingText.isEmpty {
                    let event = AgentEvent(agentId: eventScopeKey, sequence: sequence, eventType: "output")
                    event.text = streamingText; event.isComplete = true
                    event.model = streamingModel
                    modelContext.insert(event); appendEvent(event)
                }
                isStreaming = false; streamingText = ""; streamingModel = nil
                for event in events where event.eventType == "tool_use" && event.isComplete != true {
                    event.isComplete = true
                    if event.success == nil { event.success = true }
                }
            }
        case .availableCommands(let upd):
            var seen = Set<String>()
            let next = upd.commands
                .filter { !$0.name.isEmpty && seen.insert($0.name).inserted }
                .map { SlashCommand(name: $0.name,
                                    description: $0.description_p,
                                    inputHint: $0.inputHint) }
            if next != availableCommands {
                availableCommands = next
            }
            // No SwiftData mutation; `dirty` stays false.
        case .raw(let raw):
            if raw.method == "tool_title_update" {
                let payload = String(data: raw.jsonPayload, encoding: .utf8) ?? ""
                if let pipeIdx = payload.firstIndex(of: "|") {
                    let toolId = String(payload[payload.startIndex..<pipeIdx])
                    let newTitle = String(payload[payload.index(after: pipeIdx)...])
                    if let idx = toolUseIndex(forToolId: toolId) {
                        events[idx].toolName = newTitle
                        dirty = true
                    }
                }
            }
        default: break
        }
        return dirty
    }

    private func handleCollabEvent(_ collab: Amux_CollabEvent, sequence: Int) {
        switch collab.event {
        case .promptAccepted:
            // Confirmation: set runtime to active (triggers typing indicator)
            runtime?.status = Int(Amux_AgentStatus.active.rawValue)
        case .promptRejected(let pr):
            let event = AgentEvent(agentId: eventScopeKey, sequence: sequence, eventType: "error")
            event.text = "Rejected: \(pr.reason)"
            appendEvent(event)
            recomputeGroups()
        case .permissionResolved(let resolved):
            if let idx = permissionIndex(forRequestId: resolved.requestID) {
                events[idx].isComplete = true
                events[idx].success = resolved.granted
                recomputeGroups()
            }
        case .historyBatch(let batch):
            handleHistoryBatch(batch)
        case .none:
            break
        }
    }

    private var syncModelContext: ModelContext?
    public var isSyncing = false
    private var startModelContext: ModelContext?

    private func handleHistoryBatch(_ batch: Amux_HistoryBatch) {
        guard let modelContext = syncModelContext else { return }
        let existingSeqs = Set(events.compactMap { $0.sequence != 0 ? $0.sequence : nil })

        // Aggregate dirty across the batch so we save + regroup once per page
        // instead of per-event. Sort+regroup is deferred to the last page in
        // the common case where the client keeps paginating (batch.hasMore_p).
        var anyDirty = false
        for envelope in batch.events {
            let seq = Int(envelope.sequence)
            guard !existingSeqs.contains(seq) else { continue }

            if case .acpEvent(let acp) = envelope.payload {
                if handleAcpEvent(acp, sequence: seq, modelContext: modelContext) {
                    anyDirty = true
                }
            }
        }

        if anyDirty {
            try? modelContext.save()
        }

        if batch.hasMore_p {
            // Mid-sync: rebuild groups so the user sees progress, but defer
            // the O(n log n) sort to the final page.
            if anyDirty { recomputeGroups() }
            Task {
                try? await requestHistoryPage(afterSequence: batch.nextAfterSequence)
            }
        } else {
            events.sort { $0.sequence < $1.sequence }
            rebuildIndexes()
            recomputeGroups()
            isSyncing = false
        }
    }

    /// Fetch events newer than our local max sequence from the daemon.
    /// Cursor-based + paginated — cheap to call on every reconnect / foreground.
    ///
    /// Also clears any stale streaming UI state: if the app was backgrounded
    /// mid-stream and missed the `isComplete=true` or `status_change=idle`
    /// event, `isStreaming` could be stuck showing a typing indicator. The
    /// history batch will restore the correct state (and if the runtime is
    /// actually still streaming, incoming deltas will flip `isStreaming` back).
    public func requestIncrementalSync(modelContext: ModelContext) async throws {
        guard runtime != nil else { return }
        self.syncModelContext = modelContext
        isSyncing = true
        // Clear stale streaming state — will be re-established by the batch
        // (if runtime is idle now) or by fresh deltas (if it's still active).
        isStreaming = false
        streamingText = ""
        streamingModel = nil
        let maxSeq = events.compactMap({ $0.sequence != 0 ? $0.sequence : nil }).max() ?? 0
        try await requestHistoryPage(afterSequence: UInt64(maxSeq))
    }

    private func requestHistoryPage(afterSequence: UInt64) async throws {
        var req = Amux_AcpRequestHistory()
        req.afterSequence = afterSequence
        req.pageSize = 50
        req.requestID = UUID().uuidString
        try await sendCommand { $0.command = .requestHistory(req) }
    }

    private func sendCommand(_ makeCommand: (inout Amux_AcpCommand) -> Void) async throws {
        guard let runtime else { return }
        let daemonDeviceId = resolveDaemonDeviceId()
        guard !daemonDeviceId.isEmpty else {
            print("[RuntimeDetailVM] dropping command — daemon device-id not resolved (primaryAgentId=\(session?.primaryAgentId ?? "nil") runtimeId=\(runtime.runtimeId))")
            return
        }
        var cmd = Amux_RuntimeCommandEnvelope()
        cmd.runtimeID = runtime.runtimeId; cmd.deviceID = daemonDeviceId; cmd.peerID = peerId
        cmd.commandID = UUID().uuidString; cmd.timestamp = Int64(Date().timeIntervalSince1970)
        var acpCmd = Amux_AcpCommand()
        makeCommand(&acpCmd)
        cmd.acpCommand = acpCmd
        let data = try ProtoMQTTCoder.encode(cmd)
        try await mqtt.publish(topic: MQTTTopics.runtimeCommands(teamID: teamID, deviceID: daemonDeviceId, runtimeID: runtime.runtimeId), payload: data)
    }

    public func sendPrompt(_ text: String, modelId: String? = nil, modelContext: ModelContext? = nil) async throws {
        if runtime != nil {
            // Runtime session: send ACP command
            let seq = (events.last?.sequence ?? 0) + 1
            let userEvent = AgentEvent(agentId: eventScopeKey, sequence: seq, eventType: "user_prompt")
            userEvent.text = text
            if let ctx = modelContext ?? syncModelContext { ctx.insert(userEvent); try? ctx.save() }
            appendEvent(userEvent)
            recomputeGroups()

            var p = Amux_AcpSendPrompt(); p.text = text
            if let modelId, !modelId.isEmpty {
                p.modelID = modelId
            }
            try await sendCommand { $0.command = .sendPrompt(p) }
        } else if let session, let teamclawService {
            // Shared session: add local bubble + send via TeamclawService
            let seq = (events.last?.sequence ?? 0) + 1
            let userEvent = AgentEvent(agentId: eventScopeKey, sequence: seq, eventType: "user_prompt")
            userEvent.text = text
            if let ctx = modelContext ?? startModelContext { ctx.insert(userEvent); try? ctx.save() }
            appendEvent(userEvent)
            recomputeGroups()

            teamclawService.sendMessage(
                sessionId: session.sessionId,
                content: text,
                modelId: modelId
            )
        }
    }
    public func cancelTask() async throws {
        try await sendCommand { $0.command = .cancel(Amux_AcpCancel()) }
    }
    public func grantPermission(requestId: String) async throws {
        var g = Amux_AcpGrantPermission(); g.requestID = requestId
        try await sendCommand { $0.command = .grantPermission(g) }
    }
    public func denyPermission(requestId: String) async throws {
        var d = Amux_AcpDenyPermission(); d.requestID = requestId
        try await sendCommand { $0.command = .denyPermission(d) }
    }
}
