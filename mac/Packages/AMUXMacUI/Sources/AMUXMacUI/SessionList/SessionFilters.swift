import Foundation

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
