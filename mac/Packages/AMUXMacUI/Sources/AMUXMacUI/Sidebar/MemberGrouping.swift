import Foundation
import AMUXCore

public enum MemberGrouping {
    public static let unassignedKey = "Unassigned"

    public struct DepartmentGroup: Identifiable, Hashable {
        public var department: String
        public var members: [Member]
        public var id: String { department }
    }

    /// Groups members by `department` (nil or empty string → "Unassigned"),
    /// sorted alphabetically with "Unassigned" pinned to the bottom; members
    /// inside each group sort by displayName.
    public static func grouped(_ members: [Member]) -> [DepartmentGroup] {
        let buckets = Dictionary(grouping: members) { member -> String in
            let dept = member.department?.trimmingCharacters(in: .whitespaces)
            return (dept?.isEmpty == false ? dept! : unassignedKey)
        }
        let sortedKeys = buckets.keys.sorted { lhs, rhs in
            if lhs == unassignedKey { return false }
            if rhs == unassignedKey { return true }
            return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
        }
        return sortedKeys.map { key in
            let members = (buckets[key] ?? []).sorted {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
            return DepartmentGroup(department: key, members: members)
        }
    }

    /// Counts how many sessions a member co-participated in, given a precomputed
    /// `[sessionId: Set<senderActorId>]` map.
    public static func coSessionCount(
        for member: Member,
        sessionSenders: [String: Set<String>]
    ) -> Int {
        sessionSenders.values.reduce(0) { acc, senders in
            senders.contains(member.memberId) ? acc + 1 : acc
        }
    }
}
