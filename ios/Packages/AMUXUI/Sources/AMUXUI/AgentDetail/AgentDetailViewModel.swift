import Foundation
import Observation
import SwiftData
import AMUXCore

@Observable @MainActor
public final class AgentDetailViewModel {
    public var events: [AgentEvent] = []
    public var isStreaming = false
    public var streamingText = ""
    public var isDaemonOnline = true
    public let agent: Agent
    private let mqtt: MQTTService
    private let deviceId: String
    private let peerId: String
    private var task: Task<Void, Never>?

    // Expose for child views that need to pass these along
    public var mqttRef: MQTTService { mqtt }
    public var deviceIdRef: String { deviceId }
    public var peerIdRef: String { peerId }

    public init(agent: Agent, mqtt: MQTTService, deviceId: String, peerId: String) {
        self.agent = agent; self.mqtt = mqtt; self.deviceId = deviceId; self.peerId = peerId
    }

    public func start(modelContext: ModelContext) {
        task?.cancel()
        task = Task {
            // Wait for MQTT to be connected
            while mqtt.connectionState != .connected {
                try? await Task.sleep(for: .milliseconds(200))
                if Task.isCancelled { return }
            }

            let eventsTopic = "amux/\(deviceId)/agent/\(agent.agentId)/events"
            let stream = mqtt.messages()
            try? await mqtt.subscribe(eventsTopic)
            print("[AgentDetailVM] subscribed to \(eventsTopic)")
            // Load existing events for this agent from SwiftData
            let agentId = agent.agentId
            let descriptor = FetchDescriptor<AgentEvent>(
                predicate: #Predicate { $0.agentId == agentId },
                sortBy: [SortDescriptor(\.sequence)]
            )
            events = (try? modelContext.fetch(descriptor)) ?? []

            // Insert initial prompt as first user bubble if not already present
            if !agent.currentPrompt.isEmpty && !events.contains(where: { $0.eventType == "user_prompt" && $0.text == agent.currentPrompt }) {
                let promptEvent = AgentEvent(agentId: agentId, sequence: 0, eventType: "user_prompt")
                promptEvent.text = agent.currentPrompt
                events.insert(promptEvent, at: 0)
            }
            for await msg in stream {
                guard msg.topic == eventsTopic else { continue }
                guard let envelope = try? ProtoMQTTCoder.decode(Amux_Envelope.self, from: msg.payload) else { continue }
                handleEnvelope(envelope, modelContext: modelContext)
            }
        }
    }

    public func stop() { task?.cancel(); task = nil }

    private func handleEnvelope(_ env: Amux_Envelope, modelContext: ModelContext) {
        switch env.payload {
        case .acpEvent(let acp): handleAcpEvent(acp, sequence: Int(env.sequence), modelContext: modelContext)
        case .collabEvent(let collab): handleCollabEvent(collab, sequence: Int(env.sequence))
        case .none: break
        }
    }

    private func handleAcpEvent(_ acp: Amux_AcpEvent, sequence: Int, modelContext: ModelContext) {
        switch acp.event {
        case .output(let o):
            if o.isComplete {
                // Complete output — store as event
                isStreaming = false
                let event = AgentEvent(agentId: agent.agentId, sequence: sequence, eventType: "output")
                event.text = o.text; event.isComplete = true
                modelContext.insert(event); events.append(event); streamingText = ""
            } else {
                // Streaming delta
                isStreaming = true; streamingText += o.text
            }
        case .thinking(let t):
            // Append to last thinking event if it's the most recent, otherwise create new
            if let last = events.last, last.eventType == "thinking" {
                last.text = (last.text ?? "") + t.text
            } else {
                let event = AgentEvent(agentId: agent.agentId, sequence: sequence, eventType: "thinking")
                event.text = t.text; modelContext.insert(event); events.append(event)
            }
        case .toolUse(let tu):
            let event = AgentEvent(agentId: agent.agentId, sequence: sequence, eventType: "tool_use")
            event.toolName = tu.toolName; event.toolId = tu.toolID; event.text = tu.description_p
            modelContext.insert(event); events.append(event)
        case .toolResult(let tr):
            // Update matching tool_use event instead of creating separate entry
            if let idx = events.lastIndex(where: { $0.eventType == "tool_use" && $0.toolId == tr.toolID }) {
                events[idx].success = tr.success
                events[idx].isComplete = true
            } else {
                let event = AgentEvent(agentId: agent.agentId, sequence: sequence, eventType: "tool_result")
                event.toolId = tr.toolID; event.success = tr.success; event.text = tr.summary
                modelContext.insert(event); events.append(event)
            }
        case .error(let e):
            let event = AgentEvent(agentId: agent.agentId, sequence: sequence, eventType: "error")
            event.text = e.message; modelContext.insert(event); events.append(event)
        case .permissionRequest(let pr):
            let event = AgentEvent(agentId: agent.agentId, sequence: sequence, eventType: "permission_request")
            event.toolName = pr.toolName; event.toolId = pr.requestID; event.text = pr.description_p
            modelContext.insert(event); events.append(event)
        case .todoUpdate(let tu):
            // Replace existing todo event with fresh snapshot
            events.removeAll { $0.eventType == "todo_update" }
            let event = AgentEvent(agentId: agent.agentId, sequence: sequence, eventType: "todo_update")
            let lines = tu.items.map { item -> String in
                let icon = item.status == .completed ? "done" : item.status == .inProgress ? "wip" : "todo"
                return "[\(icon)] \(item.content)"
            }
            event.text = lines.joined(separator: "\n")
            modelContext.insert(event); events.append(event)
        case .statusChange(let sc):
            agent.status = Int(sc.newStatus.rawValue)
            if sc.newStatus == .idle {
                // Agent finished — flush any accumulated streaming text as a complete output event
                if isStreaming && !streamingText.isEmpty {
                    let event = AgentEvent(agentId: agent.agentId, sequence: sequence, eventType: "output")
                    event.text = streamingText; event.isComplete = true
                    modelContext.insert(event); events.append(event)
                }
                isStreaming = false; streamingText = ""
                // Mark all tool_use events as completed
                for event in events where event.eventType == "tool_use" && event.isComplete != true {
                    event.isComplete = true
                    if event.success == nil { event.success = true }
                }
            }
        case .raw(let raw):
            if raw.method == "tool_title_update" {
                let payload = String(data: raw.jsonPayload, encoding: .utf8) ?? ""
                if let pipeIdx = payload.firstIndex(of: "|") {
                    let toolId = String(payload[payload.startIndex..<pipeIdx])
                    let newTitle = String(payload[payload.index(after: pipeIdx)...])
                    if let idx = events.lastIndex(where: { $0.eventType == "tool_use" && $0.toolId == toolId }) {
                        events[idx].toolName = newTitle
                    }
                }
            }
        default: break
        }
        try? modelContext.save()
    }

    private func handleCollabEvent(_ collab: Amux_CollabEvent, sequence: Int) {
        switch collab.event {
        case .promptAccepted:
            // Confirmation: set agent to active (triggers typing indicator)
            agent.status = Int(Amux_AgentStatus.active.rawValue)
        case .promptRejected(let pr):
            let event = AgentEvent(agentId: agent.agentId, sequence: sequence, eventType: "error")
            event.text = "Rejected: \(pr.reason)"
            events.append(event)
        case .permissionResolved(let resolved):
            if let idx = events.lastIndex(where: {
                $0.eventType == "permission_request" && $0.toolId == resolved.requestID
            }) {
                events[idx].isComplete = true
                events[idx].success = resolved.granted
            }
        case .historyBatch(let batch):
            handleHistoryBatch(batch)
        case .none:
            break
        }
    }

    private var syncModelContext: ModelContext?
    public var isSyncing = false

    private func handleHistoryBatch(_ batch: Amux_HistoryBatch) {
        guard let modelContext = syncModelContext else { return }
        let existingSeqs = Set(events.compactMap { $0.sequence != 0 ? $0.sequence : nil })

        for envelope in batch.events {
            let seq = Int(envelope.sequence)
            guard !existingSeqs.contains(seq) else { continue }

            if case .acpEvent(let acp) = envelope.payload {
                handleAcpEvent(acp, sequence: seq, modelContext: modelContext)
            }
        }

        // Sort events by sequence to maintain order
        events.sort { ($0.sequence ) < ($1.sequence ) }

        if batch.hasMore_p {
            // Request next page
            Task {
                try? await requestHistoryPage(afterSequence: batch.nextAfterSequence)
            }
        } else {
            isSyncing = false
        }
    }

    public func requestFullSync(modelContext: ModelContext) async throws {
        self.syncModelContext = modelContext
        isSyncing = true
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
        var cmd = Amux_CommandEnvelope()
        cmd.agentID = agent.agentId; cmd.deviceID = deviceId; cmd.peerID = peerId
        cmd.commandID = UUID().uuidString; cmd.timestamp = Int64(Date().timeIntervalSince1970)
        var acpCmd = Amux_AcpCommand()
        makeCommand(&acpCmd)
        cmd.acpCommand = acpCmd
        let data = try ProtoMQTTCoder.encode(cmd)
        try await mqtt.publish(topic: "amux/\(deviceId)/agent/\(agent.agentId)/commands", payload: data)
    }

    public func sendPrompt(_ text: String) async throws {
        // Add local user bubble immediately
        let userEvent = AgentEvent(agentId: agent.agentId, sequence: Int(Date().timeIntervalSince1970), eventType: "user_prompt")
        userEvent.text = text
        events.append(userEvent)

        var p = Amux_AcpSendPrompt(); p.text = text
        try await sendCommand { $0.command = .sendPrompt(p) }
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
