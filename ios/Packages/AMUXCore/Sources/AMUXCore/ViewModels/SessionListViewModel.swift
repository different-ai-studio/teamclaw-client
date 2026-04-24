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

    public func start(mqtt: MQTTService, teamID: String = "", deviceId: String, modelContext: ModelContext, teamclawService: TeamclawService? = nil) {
        // Create a dedicated context from the same container for async work
        let container = modelContext.container
        let ctx = ModelContext(container)

        // Load cached data immediately
        runtimes = (try? ctx.fetch(FetchDescriptor<Runtime>(sortBy: [SortDescriptor(\.lastEventTime, order: .reverse)]))) ?? []
        workspaces = (try? ctx.fetch(FetchDescriptor<Workspace>(sortBy: [SortDescriptor(\.displayName)]))) ?? []
        sessions = (try? ctx.fetch(FetchDescriptor<Session>(sortBy: [SortDescriptor(\.lastMessageAt, order: .reverse)]))) ?? []

        guard !deviceId.isEmpty else {
            isLoading = false
            task?.cancel()
            task = nil
            return
        }

        task?.cancel()
        // Daemon fans each session out to its own retained topic
        // `device/{id}/runtime/{runtime}/state` (one RuntimeInfo per message)
        // so a single publish never relies on a large broker packet limit. We
        // subscribe to the wildcard and rebuild our dict as retained
        // messages arrive.
        let runtimeStatePrefix = MQTTTopics.runtimeStatePrefix(teamID: teamID, deviceID: deviceId)
        let runtimeStateSuffix = "/state"
        let runtimeStateWildcard = MQTTTopics.runtimeStateWildcard(teamID: teamID, deviceID: deviceId)
        task = Task {
            // Outer loop: each iteration represents a fresh MQTT connection
            // lifecycle. When the inner stream ends (disconnect clears
            // continuations), loop back, wait for reconnect, and resubscribe
            // so the broker re-delivers retained runtime/workspace lists.
            // Mirrors the pattern RuntimeDetailViewModel uses.
            while !Task.isCancelled {
                var waited = 0
                while mqtt.connectionState != .connected {
                    try? await Task.sleep(for: .milliseconds(200))
                    if Task.isCancelled { return }
                    waited += 200
                    if waited >= 15_000 {
                        NSLog("[SessionListVM] timed out waiting for MQTT (state: %@)", String(describing: mqtt.connectionState))
                        isLoading = false
                        // Keep looping — user-triggered reconnect will flip
                        // connectionState and unblock the next iteration.
                        break
                    }
                }
                if Task.isCancelled { return }
                if mqtt.connectionState != .connected {
                    try? await Task.sleep(for: .seconds(1))
                    continue
                }

                let stream = mqtt.messages()
                try? await mqtt.subscribe(runtimeStateWildcard)
                isLoading = false
                NSLog("[SessionListVM] subscribed to %@", runtimeStateWildcard)

                // Phase 2b: workspaces come from FetchWorkspaces RPC instead
                // of retained topic subscription. One-shot fetch on connect.
                // Phase 2c will call syncWorkspaces from workspace-mutation
                // success handlers; until then, users don't see changes made
                // from other devices until they reconnect. Acceptable for the
                // compat window since daemon still publishes retained
                // deviceWorkspaces for pre-Phase-2b clients.
                if let teamclawService {
                    Task { [weak self] in
                        guard let self else { return }
                        let workspaces = await teamclawService.fetchWorkspaces()
                        syncWorkspaces(workspaces, modelContext: ctx)
                    }
                }

                for await msg in stream {
                    guard msg.topic.hasPrefix(runtimeStatePrefix),
                          msg.topic.hasSuffix(runtimeStateSuffix) else { continue }
                    // Empty retained payload = the daemon cleared this runtime's
                    // slot (session deletion). Drop the local row to match.
                    if msg.payload.isEmpty {
                        let runtimeId = String(msg.topic.dropFirst(runtimeStatePrefix.count).dropLast(runtimeStateSuffix.count))
                        removeRuntime(runtimeId: runtimeId, modelContext: ctx)
                        refreshSessions(modelContext: ctx)
                        continue
                    }
                    guard let info = try? ProtoMQTTCoder.decode(Amux_RuntimeInfo.self, from: msg.payload) else { continue }
                    syncRuntime(info, modelContext: ctx)
                    refreshSessions(modelContext: ctx)
                }
                if Task.isCancelled { return }
                NSLog("[SessionListVM] stream ended, waiting to resubscribe…")
            }
        }
    }

    public func stop() { task?.cancel(); task = nil }

    private func syncRuntime(_ proto: Amux_RuntimeInfo, modelContext: ModelContext) {
        let id = proto.runtimeID
        let descriptor = FetchDescriptor<Runtime>(predicate: #Predicate { $0.runtimeId == id })
        if let existing = try? modelContext.fetch(descriptor).first {
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
            session.taskId = record.taskID ?? ""
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
