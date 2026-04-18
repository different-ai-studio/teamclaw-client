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

public struct SessionDateGroup: Identifiable {
    public let id: String
    public let title: String
    public var sessions: [CollabSession]
}

public enum SessionGrouping {
    /// Buckets a list of sessions into iOS-matching date sections:
    /// Today / Yesterday / This Week / This Month / Older.
    /// Sort within each bucket is preserved (caller sorts the input).
    public static func grouped(_ sessions: [CollabSession], now: Date = .now) -> [SessionDateGroup] {
        let calendar = Calendar.current

        var today: [CollabSession] = []
        var yesterday: [CollabSession] = []
        var thisWeek: [CollabSession] = []
        var thisMonth: [CollabSession] = []
        var older: [CollabSession] = []

        let weekAgo = calendar.date(byAdding: .day, value: -7, to: now)
        let monthAgo = calendar.date(byAdding: .month, value: -1, to: now)

        for session in sessions {
            let date = session.lastMessageAt ?? session.createdAt
            if calendar.isDateInToday(date) {
                today.append(session)
            } else if calendar.isDateInYesterday(date) {
                yesterday.append(session)
            } else if let weekAgo, date > weekAgo {
                thisWeek.append(session)
            } else if let monthAgo, date > monthAgo {
                thisMonth.append(session)
            } else {
                older.append(session)
            }
        }

        var groups: [SessionDateGroup] = []
        if !today.isEmpty { groups.append(.init(id: "today", title: "Today", sessions: today)) }
        if !yesterday.isEmpty { groups.append(.init(id: "yesterday", title: "Yesterday", sessions: yesterday)) }
        if !thisWeek.isEmpty { groups.append(.init(id: "week", title: "This Week", sessions: thisWeek)) }
        if !thisMonth.isEmpty { groups.append(.init(id: "month", title: "This Month", sessions: thisMonth)) }
        if !older.isEmpty { groups.append(.init(id: "older", title: "Older", sessions: older)) }
        return groups
    }
}
