import Foundation
import Observation
import SwiftData
import AMUXCore

// MARK: - AgentGroup

public struct AgentGroup: Identifiable {
    public let id: String
    public let title: String
    public var agents: [Agent]
}

@Observable @MainActor
public final class SessionListViewModel {
    public var agents: [Agent] = []
    public var workspaces: [Workspace] = []
    public var collabSessions: [CollabSession] = []
    public var isLoading = true
    public var searchText = ""
    private var task: Task<Void, Never>?

    public init() {}

    public func start(mqtt: MQTTService, deviceId: String, modelContext: ModelContext) {
        // Create a dedicated context from the same container for async work
        let container = modelContext.container
        let ctx = ModelContext(container)

        // Load cached data immediately
        agents = (try? ctx.fetch(FetchDescriptor<Agent>(sortBy: [SortDescriptor(\.lastEventTime, order: .reverse)]))) ?? []
        workspaces = (try? ctx.fetch(FetchDescriptor<Workspace>(sortBy: [SortDescriptor(\.displayName)]))) ?? []
        collabSessions = (try? ctx.fetch(FetchDescriptor<CollabSession>(sortBy: [SortDescriptor(\.lastMessageAt, order: .reverse)]))) ?? []

        task?.cancel()
        task = Task {
            let agentsTopic = "amux/\(deviceId)/agents"

            // Wait for MQTT to be connected (up to 15s)
            var waited = 0
            while mqtt.connectionState != .connected {
                try? await Task.sleep(for: .milliseconds(200))
                if Task.isCancelled { return }
                waited += 200
                if waited >= 15_000 {
                    print("[SessionListVM] timed out waiting for MQTT (state: \(mqtt.connectionState))")
                    isLoading = false
                    return
                }
            }

            let workspacesTopic = "amux/\(deviceId)/workspaces"

            let stream = mqtt.messages()
            try? await mqtt.subscribe(agentsTopic)
            try? await mqtt.subscribe(workspacesTopic)
            isLoading = false
            print("[SessionListVM] subscribed to \(agentsTopic), waiting...")

            NSLog("[SessionListVM] subscribed to workspaces topic: %@", workspacesTopic)
            for await msg in stream {
                if msg.topic == workspacesTopic {
                    NSLog("[SessionListVM] received workspaces msg, %d bytes", msg.payload.count)
                    if let list = try? ProtoMQTTCoder.decode(Amux_WorkspaceList.self, from: msg.payload) {
                        NSLog("[SessionListVM] decoded WorkspaceList: %d workspaces", list.workspaces.count)
                        syncWorkspaces(list, modelContext: ctx)
                    } else {
                        NSLog("[SessionListVM] FAILED to decode WorkspaceList")
                    }
                    continue
                }

                guard msg.topic == agentsTopic else { continue }
                guard let list = try? ProtoMQTTCoder.decode(Amux_AgentList.self, from: msg.payload) else { continue }
                print("[SessionListVM] AgentList: \(list.agents.count) agents")
                syncAgents(list, modelContext: ctx)
                refreshCollabSessions(modelContext: ctx)
            }
        }
    }

    public func stop() { task?.cancel(); task = nil }

    private func syncAgents(_ list: Amux_AgentList, modelContext: ModelContext) {
        let incoming = Set(list.agents.map { $0.agentID })
        for proto in list.agents {
            let id = proto.agentID
            let descriptor = FetchDescriptor<Agent>(predicate: #Predicate { $0.agentId == id })
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
            } else {
                let newAgent = Agent(
                    agentId: proto.agentID,
                    agentType: Int(proto.agentType.rawValue),
                    worktree: proto.worktree,
                    branch: proto.branch,
                    status: Int(proto.status.rawValue),
                    startedAt: Date(timeIntervalSince1970: TimeInterval(proto.startedAt)),
                    currentPrompt: proto.currentPrompt,
                    workspaceId: proto.workspaceID
                )
                newAgent.lastEventTime = .now
                newAgent.hasUnread = true
                modelContext.insert(newAgent)
            }
        }
        try? modelContext.save()
        agents = (try? modelContext.fetch(FetchDescriptor<Agent>(sortBy: [SortDescriptor(\.lastEventTime, order: .reverse)]))) ?? []
    }

    private func syncWorkspaces(_ list: Amux_WorkspaceList, modelContext: ModelContext) {
        for proto in list.workspaces {
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

    private func refreshCollabSessions(modelContext: ModelContext) {
        collabSessions = (try? modelContext.fetch(FetchDescriptor<CollabSession>(sortBy: [SortDescriptor(\.lastMessageAt, order: .reverse)]))) ?? []
    }

    /// Call this from views when collab sessions are known to have changed (e.g. after TeamclawService sync).
    public func reloadCollabSessions(modelContext: ModelContext) {
        collabSessions = (try? modelContext.fetch(FetchDescriptor<CollabSession>(sortBy: [SortDescriptor(\.lastMessageAt, order: .reverse)]))) ?? []
    }

    public var filteredAgents: [Agent] {
        if searchText.isEmpty { return agents }
        let q = searchText.lowercased()
        return agents.filter {
            $0.worktree.lowercased().contains(q) || $0.currentPrompt.lowercased().contains(q) || $0.agentId.lowercased().contains(q)
        }
    }

    // MARK: - Time Grouping

    public var groupedFilteredAgents: [AgentGroup] {
        let sorted = filteredAgents
        var groups: [AgentGroup] = []
        let calendar = Calendar.current
        let now = Date()

        var todayAgents: [Agent] = []
        var yesterdayAgents: [Agent] = []
        var thisWeekAgents: [Agent] = []
        var thisMonthAgents: [Agent] = []
        var olderAgents: [Agent] = []

        for agent in sorted {
            let date = agent.lastEventTime ?? agent.startedAt
            if calendar.isDateInToday(date) {
                todayAgents.append(agent)
            } else if calendar.isDateInYesterday(date) {
                yesterdayAgents.append(agent)
            } else if let weekAgo = calendar.date(byAdding: .day, value: -7, to: now), date > weekAgo {
                thisWeekAgents.append(agent)
            } else if let monthAgo = calendar.date(byAdding: .month, value: -1, to: now), date > monthAgo {
                thisMonthAgents.append(agent)
            } else {
                olderAgents.append(agent)
            }
        }

        if !todayAgents.isEmpty { groups.append(AgentGroup(id: "today", title: "Today", agents: todayAgents)) }
        if !yesterdayAgents.isEmpty { groups.append(AgentGroup(id: "yesterday", title: "Yesterday", agents: yesterdayAgents)) }
        if !thisWeekAgents.isEmpty { groups.append(AgentGroup(id: "week", title: "This Week", agents: thisWeekAgents)) }
        if !thisMonthAgents.isEmpty { groups.append(AgentGroup(id: "month", title: "This Month", agents: thisMonthAgents)) }
        if !olderAgents.isEmpty { groups.append(AgentGroup(id: "older", title: "Older", agents: olderAgents)) }

        return groups
    }
}
