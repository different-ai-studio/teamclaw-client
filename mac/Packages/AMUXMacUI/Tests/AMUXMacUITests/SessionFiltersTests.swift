import Testing
import Foundation
@testable import AMUXMacUI

@Suite("SessionFilters")
struct SessionFiltersTests {

    @Test("all returns input unchanged when memberId is nil")
    func allWhenNil() {
        let senders: [String: Set<String>] = [
            "s1": ["alice"],
            "s2": ["bob"],
        ]
        #expect(SessionFilters.sessionIdsInvolving(memberId: nil, sessionSenders: senders) == nil)
    }

    @Test("returns ids of sessions in which the member appears as a sender")
    func filtersByMember() {
        let senders: [String: Set<String>] = [
            "s1": ["alice", "bob"],
            "s2": ["alice"],
            "s3": ["carol"],
        ]
        let result = SessionFilters.sessionIdsInvolving(memberId: "alice", sessionSenders: senders)
        #expect(result == Set(["s1", "s2"]))
    }

    @Test("returns empty set when member has no participation")
    func emptyForUnknownMember() {
        let senders: [String: Set<String>] = ["s1": ["alice"]]
        let result = SessionFilters.sessionIdsInvolving(memberId: "stranger", sessionSenders: senders)
        #expect(result == [])
    }
}
