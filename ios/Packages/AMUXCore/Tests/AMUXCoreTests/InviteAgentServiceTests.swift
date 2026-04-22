import Testing
import Foundation
@testable import AMUXCore

@Suite("InviteAgentService")
struct InviteAgentServiceTests {

    @Test("buildJoinURL emits amux://join with token, url, anon query items")
    func testBuildsJoinURL() throws {
        let token = UUID(uuidString: "9f6b6e53-8d4e-4f7a-9f58-d9d1c7b2e8a5")!
        let url = InviteAgentService.buildJoinURL(
            token: token,
            supabaseURL: URL(string: "https://x.supabase.co")!,
            anonKey: "anon123"
        )
        #expect(url.scheme == "amux")
        #expect(url.host == "join")
        let s = url.absoluteString
        #expect(s.contains("token=9f6b6e53"))
        #expect(s.contains("url=https%3A%2F%2Fx.supabase.co"))
        #expect(s.contains("anon=anon123"))
    }
}
