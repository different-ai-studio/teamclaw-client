import Foundation
import SwiftData

@Model
public final class Member {
    @Attribute(.unique) public var memberId: String
    public var displayName: String
    public var role: Int
    public var joinedAt: Date
    public var department: String?

    public init(
        memberId: String,
        displayName: String,
        role: Int = 1,
        joinedAt: Date = .now,
        department: String? = nil
    ) {
        self.memberId = memberId
        self.displayName = displayName
        self.role = role
        self.joinedAt = joinedAt
        self.department = department
    }

    public var isOwner: Bool { role == 0 }
    public var roleLabel: String { isOwner ? "Owner" : "Member" }
}
