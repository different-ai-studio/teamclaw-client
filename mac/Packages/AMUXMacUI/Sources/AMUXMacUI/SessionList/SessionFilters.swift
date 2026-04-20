import Foundation
import AMUXCore

public enum SessionFilters {
    /// Returns the set of session ids that contain a message authored by `memberId`,
    /// or `nil` when no member filter should be applied (caller shows all sessions).
    public static func sessionIdsInvolving(
        memberId: String?,
        sessionSenders: [String: Set<String>]
    ) -> Set<String>? {
        guard let memberId else { return nil }
        var ids: Set<String> = []
        for (sessionId, senders) in sessionSenders where senders.contains(memberId) {
            ids.insert(sessionId)
        }
        return ids
    }
}

// MARK: - Date Grouping

/// Union row type for the Mac session list. Mirrors iOS's `SessionItem` so
/// the Mac column can display both shared sessions and solo Agents
/// (agents spawned without any collaborators never acquire a shared session
/// wrapper, so without this union they stayed invisible — see 2026-04-20
/// regression debugging).
public enum SessionListItem: Identifiable {
    case agent(Agent)
    case collab(Session)

    public var id: String {
        switch self {
        case .agent(let a): return "agent:\(a.agentId)"
        case .collab(let c): return "collab:\(c.sessionId)"
        }
    }

    public var date: Date {
        switch self {
        case .agent(let a): return a.lastEventTime ?? a.startedAt
        case .collab(let c): return c.lastMessageAt ?? c.createdAt
        }
    }
}

public struct SessionDateGroup: Identifiable {
    public let id: String
    public let title: String
    public var items: [SessionListItem]
}

public enum SessionGrouping {
    /// Buckets mixed session items into iOS-matching date sections:
    /// Today / Yesterday / This Week / This Month / Older.
    /// Sort within each bucket is preserved (caller sorts the input).
    public static func grouped(_ items: [SessionListItem], now: Date = .now) -> [SessionDateGroup] {
        let calendar = Calendar.current

        var today: [SessionListItem] = []
        var yesterday: [SessionListItem] = []
        var thisWeek: [SessionListItem] = []
        var thisMonth: [SessionListItem] = []
        var older: [SessionListItem] = []

        let weekAgo = calendar.date(byAdding: .day, value: -7, to: now)
        let monthAgo = calendar.date(byAdding: .month, value: -1, to: now)

        for item in items {
            let date = item.date
            if calendar.isDateInToday(date) {
                today.append(item)
            } else if calendar.isDateInYesterday(date) {
                yesterday.append(item)
            } else if let weekAgo, date > weekAgo {
                thisWeek.append(item)
            } else if let monthAgo, date > monthAgo {
                thisMonth.append(item)
            } else {
                older.append(item)
            }
        }

        var groups: [SessionDateGroup] = []
        if !today.isEmpty { groups.append(.init(id: "today", title: "Today", items: today)) }
        if !yesterday.isEmpty { groups.append(.init(id: "yesterday", title: "Yesterday", items: yesterday)) }
        if !thisWeek.isEmpty { groups.append(.init(id: "week", title: "This Week", items: thisWeek)) }
        if !thisMonth.isEmpty { groups.append(.init(id: "month", title: "This Month", items: thisMonth)) }
        if !older.isEmpty { groups.append(.init(id: "older", title: "Older", items: older)) }
        return groups
    }
}
