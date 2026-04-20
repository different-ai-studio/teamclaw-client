import Foundation

/// Payload for opening `InviteWindow` via `openWindow(id:value:)`.
public enum InviteIntent: Codable, Hashable {
    case newMember(role: String)  // "owner" | "member"
}
