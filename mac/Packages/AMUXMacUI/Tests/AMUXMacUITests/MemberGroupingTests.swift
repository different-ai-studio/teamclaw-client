import Testing
import Foundation
import AMUXCore
@testable import AMUXMacUI

@Suite("MemberGrouping")
struct MemberGroupingTests {

    private func makeMember(id: String, name: String, department: String? = nil) -> Member {
        Member(memberId: id, displayName: name, role: 1, joinedAt: .now, department: department)
    }

    @Test("groups members by department, sorted alphabetically by department then by name")
    func groupsByDepartment() {
        let members = [
            makeMember(id: "1", name: "Alice", department: "Engineering"),
            makeMember(id: "2", name: "Bob", department: "Design"),
            makeMember(id: "3", name: "Carol", department: "Engineering"),
            makeMember(id: "4", name: "Dave"),  // no department
        ]
        let groups = MemberGrouping.grouped(members)
        #expect(groups.map(\.department) == ["Design", "Engineering", "Unassigned"])
        #expect(groups[0].members.map(\.displayName) == ["Bob"])
        #expect(groups[1].members.map(\.displayName) == ["Alice", "Carol"])
        #expect(groups[2].members.map(\.displayName) == ["Dave"])
    }

    @Test("returns empty array for empty members")
    func emptyMembers() {
        #expect(MemberGrouping.grouped([]).isEmpty)
    }

    @Test("members with empty-string department go to Unassigned")
    func emptyStringTreatedAsUnassigned() {
        let members = [
            makeMember(id: "1", name: "Alice", department: ""),
            makeMember(id: "2", name: "Bob", department: nil),
        ]
        let groups = MemberGrouping.grouped(members)
        #expect(groups.map(\.department) == ["Unassigned"])
        #expect(groups[0].members.count == 2)
    }

    @Test("counts co-sessions per member from a session list and sender mapping")
    func coSessionCount() {
        let alice = makeMember(id: "alice", name: "Alice")
        let bob = makeMember(id: "bob", name: "Bob")
        let sessionSenders: [String: Set<String>] = [
            "s1": ["alice", "bob"],
            "s2": ["alice"],
            "s3": ["bob", "carol"],
        ]
        #expect(MemberGrouping.coSessionCount(for: alice, sessionSenders: sessionSenders) == 2)
        #expect(MemberGrouping.coSessionCount(for: bob, sessionSenders: sessionSenders) == 2)
    }
}
