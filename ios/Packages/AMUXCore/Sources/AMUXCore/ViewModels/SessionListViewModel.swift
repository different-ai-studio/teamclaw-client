import Foundation
import Observation
import SwiftData

// MARK: - SessionItem

public enum SessionItem: Identifiable {
    case runtime(Runtime)
    case collab(Session)

    public var id: String {
        switch self {
        case .runtime(let r): return r.runtimeId
        case .collab(let c): return "collab:\(c.sessionId)"
        }
    }

    public var date: Date {
        switch self {
        case .runtime(let r): return r.lastEventTime ?? r.startedAt
        case .collab(let c): return c.lastMessageAt ?? c.createdAt
        }
    }
}

public struct SessionGroup: Identifiable {
    public let id: String
    public let title: String
    public var items: [SessionItem]
}

@Observable @MainActor
public final class SessionListViewModel {
    public var runtimes: [Runtime] = []
    public var workspaces: [Workspace] = []
    public var sessions: [Session] = []
    public var isLoading = true
    public var searchText = ""
    private var task: Task<Void, Never>?

    public init() {}

    public func start(mqtt: MQTTService,
                      teamID: String = "",
                      connectedAgentsStore: ConnectedAgentsStore?,
                      modelContext: ModelContext,
                      teamclawService: TeamclawService? = nil) {
        // Create a dedicated context from the same container for async work
        let container = modelContext.container
        let ctx = ModelContext(container)

        // Load cached data immediately
        runtimes = (try? ctx.fetch(FetchDescriptor<Runtime>(sortBy: [SortDescriptor(\.lastEventTime, order: .reverse)]))) ?? []
        workspaces = (try? ctx.fetch(FetchDescriptor<Workspace>(sortBy: [SortDescriptor(\.displayName)]))) ?? []
        sessions = (try? ctx.fetch(FetchDescriptor<Session>(sortBy: [SortDescriptor(\.lastMessageAt, order: .reverse)]))) ?? []

        task?.cancel()

        // Daemon fans each session out to its own retained topic
        // `device/{daemon_device_id}/runtime/{runtime}/state` (one RuntimeInfo
        // per message). With multiple daemons in scope we maintain one
        // wildcard subscription per known daemon device-id and re-sync the set
        // whenever ConnectedAgentsStore reloads. Topic shape filtering happens
        // in `parseRuntimeStateTopic`; the per-device subscriptions just gate
        // delivery from the broker.
        task = Task { [weak self] in
            guard let self else { return }
            // Outer loop: each iteration represents a fresh MQTT connection
            // lifecycle. When the inner stream ends (disconnect clears
            // continuations), loop back, wait for reconnect, and resubscribe
            // so the broker re-delivers retained runtime/workspace lists.
            while !Task.isCancelled {
                var waited = 0
                while mqtt.connectionState != .connected {
                    try? await Task.sleep(for: .milliseconds(200))
                    if Task.isCancelled { return }
                    waited += 200
                    if waited >= 15_000 {
                        NSLog("[SessionListVM] timed out waiting for MQTT (state: %@)", String(describing: mqtt.connectionState))
                        isLoading = false
                        break
                    }
                }
                if Task.isCancelled { return }
                if mqtt.connectionState != .connected {
                    try? await Task.sleep(for: .seconds(1))
                    continue
                }

                let stream = mqtt.messages()

                // Per-agent subscription set, kept in sync with
                // connectedAgentsStore.agents via Observation tracking below.
                await self.resyncRuntimeStateSubscriptions(
                    mqtt: mqtt,
                    teamID: teamID,
                    store: connectedAgentsStore
                )
                self.isLoading = false

                let observer = Task { [weak self] in
                    guard let self else { return }
                    while !Task.isCancelled {
                        await self.waitForAgentsMutation(store: connectedAgentsStore)
                        if Task.isCancelled { return }
                        await self.resyncRuntimeStateSubscriptions(
                            mqtt: mqtt,
                            teamID: teamID,
                            store: connectedAgentsStore
                        )
                    }
                }

                if let teamclawService {
                    Task { [weak self] in
                        guard let self else { return }
                        let workspaces = await teamclawService.fetchWorkspaces()
                        self.syncWorkspaces(workspaces, modelContext: ctx)
                    }
                }

                for await msg in stream {
                    guard let parsed = Self.parseRuntimeStateTopic(msg.topic, teamID: teamID) else { continue }
                    // Empty retained payload = the daemon cleared this runtime's
                    // slot (session deletion). Drop the local row to match.
                    if msg.payload.isEmpty {
                        self.removeRuntime(runtimeId: parsed.runtimeId, modelContext: ctx)
                        self.refreshSessions(modelContext: ctx)
                        continue
                    }
                    guard let info = try? ProtoMQTTCoder.decode(Amux_RuntimeInfo.self, from: msg.payload) else { continue }
                    self.syncRuntime(info, daemonDeviceId: parsed.daemonDeviceId, modelContext: ctx)
                    self.refreshSessions(modelContext: ctx)
                }
                observer.cancel()
                if Task.isCancelled { return }
                NSLog("[SessionListVM] stream ended, waiting to resubscribe…")
            }
        }
    }

    public func stop() { task?.cancel(); task = nil }

    /// Diffs the desired daemon device-id set against the currently subscribed
    /// set and adjusts `runtime/+/state` subscriptions accordingly. Idempotent.
    private func resyncRuntimeStateSubscriptions(
        mqtt: MQTTService,
        teamID: String,
        store: ConnectedAgentsStore?
    ) async {
        let desired: Set<String> = {
            guard let store else { return [] }
            return Set(store.agents.compactMap(\.deviceID).filter { !$0.isEmpty })
        }()
        let toAdd = desired.subtracting(subscribedDeviceIDs)
        let toRemove = subscribedDeviceIDs.subtracting(desired)
        for id in toAdd {
            let topic = MQTTTopics.runtimeStateWildcard(teamID: teamID, deviceID: id)
            try? await mqtt.subscribe(topic)
            NSLog("[SessionListVM] subscribed to %@", topic)
        }
        for id in toRemove {
            let topic = MQTTTopics.runtimeStateWildcard(teamID: teamID, deviceID: id)
            try? await mqtt.unsubscribe(topic)
        }
        subscribedDeviceIDs = desired
    }

    /// Suspends until any tracked property of `store.agents` mutates. Returns
    /// immediately if the store is nil.
    private func waitForAgentsMutation(store: ConnectedAgentsStore?) async {
        guard let store else {
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

    /// Returns the daemon device-id and runtime-id when `topic` matches
    /// `amux/{team}/device/{dev}/runtime/{rid}/state`. Nil otherwise.
    private static func parseRuntimeStateTopic(_ topic: String, teamID: String) -> (daemonDeviceId: String, runtimeId: String)? {
        let parts = topic.split(separator: "/")
        guard parts.count == 7,
              parts[0] == "amux",
              parts[2] == "device",
              parts[4] == "runtime",
              parts[6] == "state" else {
            return nil
        }
        let normalizedTeam = MQTTTopics.normalizedTeamID(teamID)
        guard parts[1] == Substring(normalizedTeam) else { return nil }
        return (daemonDeviceId: String(parts[3]), runtimeId: String(parts[5]))
    }

    private func syncRuntime(_ proto: Amux_RuntimeInfo, daemonDeviceId: String, modelContext: ModelContext) {
        let id = proto.runtimeID
        let descriptor = FetchDescriptor<Runtime>(predicate: #Predicate { $0.runtimeId == id })
        if let existing = try? modelContext.fetch(descriptor).first {
            existing.daemonDeviceId = daemonDeviceId
            // Mark unread and update timestamp if there's new activity
            if existing.lastOutputSummary != proto.lastOutputSummary
                || existing.toolUseCount != Int(proto.toolUseCount) {
                existing.hasUnread = true
                existing.lastEventTime = .now
            }
            existing.status = Int(proto.status.rawValue)
            existing.worktree = proto.worktree
            existing.branch = proto.branch
            existing.currentPrompt = proto.currentPrompt
            existing.workspaceId = proto.workspaceID
            if !proto.sessionTitle.isEmpty { existing.sessionTitle = proto.sessionTitle }
            existing.lastOutputSummary = proto.lastOutputSummary
            existing.toolUseCount = Int(proto.toolUseCount)
            // Historical sessions publish an empty available_models list; only
            // overwrite when the live runtime actually provided one so the
            // cached model list from a prior live publish survives.
            if !proto.availableModels.isEmpty {
                let models = proto.availableModels.map { AvailableModel(id: $0.id, displayName: $0.displayName) }
                if let json = try? JSONEncoder().encode(models),
                   let str = String(data: json, encoding: .utf8) {
                    existing.availableModelsJSON = str
                }
            }
            existing.currentModel = proto.currentModel.isEmpty ? nil : proto.currentModel
        } else {
            let newRuntime = Runtime(
                runtimeId: proto.runtimeID,
                agentType: Int(proto.agentType.rawValue),
                worktree: proto.worktree,
                branch: proto.branch,
                status: Int(proto.status.rawValue),
                startedAt: Date(timeIntervalSince1970: TimeInterval(proto.startedAt)),
                currentPrompt: proto.currentPrompt,
                workspaceId: proto.workspaceID
            )
            newRuntime.lastEventTime = .now
            newRuntime.hasUnread = true
            newRuntime.daemonDeviceId = daemonDeviceId
            let models = proto.availableModels.map { AvailableModel(id: $0.id, displayName: $0.displayName) }
            if let json = try? JSONEncoder().encode(models),
               let str = String(data: json, encoding: .utf8) {
                newRuntime.availableModelsJSON = str
            }
            newRuntime.currentModel = proto.currentModel.isEmpty ? nil : proto.currentModel
            modelContext.insert(newRuntime)
        }
        try? modelContext.save()
        runtimes = (try? modelContext.fetch(FetchDescriptor<Runtime>(sortBy: [SortDescriptor(\.lastEventTime, order: .reverse)]))) ?? []
    }

    private func removeRuntime(runtimeId: String, modelContext: ModelContext) {
        let descriptor = FetchDescriptor<Runtime>(predicate: #Predicate { $0.runtimeId == runtimeId })
        if let existing = try? modelContext.fetch(descriptor).first {
            modelContext.delete(existing)
            try? modelContext.save()
        }
        runtimes = (try? modelContext.fetch(FetchDescriptor<Runtime>(sortBy: [SortDescriptor(\.lastEventTime, order: .reverse)]))) ?? []
    }

    private func syncWorkspaces(_ infos: [Amux_WorkspaceInfo], modelContext: ModelContext) {
        for proto in infos {
            let id = proto.workspaceID
            let descriptor = FetchDescriptor<Workspace>(predicate: #Predicate { $0.workspaceId == id })
            if let existing = try? modelContext.fetch(descriptor).first {
                existing.path = proto.path
                existing.displayName = proto.displayName
                NSLog("[SessionListVM] updated workspace: %@ (%@)", proto.displayName, id)
            } else {
                modelContext.insert(Workspace(
                    workspaceId: proto.workspaceID,
                    path: proto.path,
                    displayName: proto.displayName
                ))
                NSLog("[SessionListVM] inserted workspace: %@ (%@)", proto.displayName, id)
            }
        }
        do {
            try modelContext.save()
            NSLog("[SessionListVM] save OK")
        } catch {
            NSLog("[SessionListVM] save FAILED: %@", error.localizedDescription)
        }
        let fetched = (try? modelContext.fetch(FetchDescriptor<Workspace>(sortBy: [SortDescriptor(\.displayName)]))) ?? []
        NSLog("[SessionListVM] fetched %d workspaces from SwiftData, setting viewModel.workspaces", fetched.count)
        workspaces = fetched
    }

    private func refreshSessions(modelContext: ModelContext) {
        sessions = (try? modelContext.fetch(FetchDescriptor<Session>(sortBy: [SortDescriptor(\.lastMessageAt, order: .reverse)]))) ?? []
    }

    /// Authoritative session IDs for the active team, fetched from Supabase.
    /// When non-nil, `reloadSessions` prunes any local SwiftData rows whose
    /// `sessionId` isn't in the set — this is how we keep MQTT-retained
    /// session garbage on the shared broker from showing up in the list.
    public var validSessionIDs: Set<String>?

    /// Daemon device-ids whose `runtime/+/state` topic we currently hold an
    /// active subscription on. Mutated only by `resyncRuntimeStateSubscriptions`.
    private var subscribedDeviceIDs: Set<String> = []

    /// Call this from views when sessions are known to have changed (e.g. after TeamclawService sync).
    public func reloadSessions(modelContext: ModelContext) {
        if let validIDs = validSessionIDs {
            let all = (try? modelContext.fetch(FetchDescriptor<Session>())) ?? []
            var didDelete = false
            for row in all where !validIDs.contains(row.sessionId) {
                modelContext.delete(row)
                didDelete = true
            }
            if didDelete { try? modelContext.save() }
        }
        sessions = (try? modelContext.fetch(FetchDescriptor<Session>(sortBy: [SortDescriptor(\.lastMessageAt, order: .reverse)]))) ?? []
    }

    public func syncSessionRecords(_ records: [SessionRecord], modelContext: ModelContext) {
        validSessionIDs = Set(records.map(\.id))

        let existing = (try? modelContext.fetch(FetchDescriptor<Session>())) ?? []
        var byID = Dictionary(uniqueKeysWithValues: existing.map { ($0.sessionId, $0) })

        for record in records {
            let session = byID.removeValue(forKey: record.id) ?? {
                let created = Session(sessionId: record.id)
                modelContext.insert(created)
                return created
            }()

            session.mode = record.mode
            session.teamId = record.teamID
            session.title = record.title
            session.createdBy = record.createdByActorID
            session.createdAt = record.createdAt
            session.summary = record.summary
            session.participantCount = record.participantCount
            session.lastMessagePreview = record.lastMessagePreview
            session.lastMessageAt = record.lastMessageAt
            session.ideaId = record.ideaID ?? ""
            session.primaryAgentId = record.primaryAgentID
        }

        for stale in byID.values {
            modelContext.delete(stale)
        }

        try? modelContext.save()
        reloadSessions(modelContext: modelContext)
    }

    public var filteredRuntimes: [Runtime] {
        if searchText.isEmpty { return runtimes }
        let q = searchText.lowercased()
        return runtimes.filter {
            $0.worktree.lowercased().contains(q) || $0.currentPrompt.lowercased().contains(q) || $0.runtimeId.lowercased().contains(q)
        }
    }

    // MARK: - Time Grouping

    public var groupedSessions: [SessionGroup] {
        // Merge runtimes and shared sessions into one list
        var allItems: [SessionItem] = filteredRuntimes.map { .runtime($0) }
        for session in sessions {
            if searchText.isEmpty || session.title.lowercased().contains(searchText.lowercased()) {
                allItems.append(.collab(session))
            }
        }
        allItems.sort { $0.date > $1.date }

        var groups: [SessionGroup] = []
        let calendar = Calendar.current
        let now = Date()

        var today: [SessionItem] = []
        var yesterday: [SessionItem] = []
        var thisWeek: [SessionItem] = []
        var thisMonth: [SessionItem] = []
        var older: [SessionItem] = []

        for item in allItems {
            let date = item.date
            if calendar.isDateInToday(date) {
                today.append(item)
            } else if calendar.isDateInYesterday(date) {
                yesterday.append(item)
            } else if let weekAgo = calendar.date(byAdding: .day, value: -7, to: now), date > weekAgo {
                thisWeek.append(item)
            } else if let monthAgo = calendar.date(byAdding: .month, value: -1, to: now), date > monthAgo {
                thisMonth.append(item)
            } else {
                older.append(item)
            }
        }

        if !today.isEmpty { groups.append(SessionGroup(id: "today", title: "Today", items: today)) }
        if !yesterday.isEmpty { groups.append(SessionGroup(id: "yesterday", title: "Yesterday", items: yesterday)) }
        if !thisWeek.isEmpty { groups.append(SessionGroup(id: "week", title: "This Week", items: thisWeek)) }
        if !thisMonth.isEmpty { groups.append(SessionGroup(id: "month", title: "This Month", items: thisMonth)) }
        if !older.isEmpty { groups.append(SessionGroup(id: "older", title: "Older", items: older)) }

        return groups
    }
}
