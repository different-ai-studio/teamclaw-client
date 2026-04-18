import SwiftUI
import SwiftData
import AMUXCore

public struct DetailWindowScene: Scene {
    let pairing: PairingManager
    let teamclawService: TeamclawService

    public init(pairing: PairingManager, teamclawService: TeamclawService) {
        self.pairing = pairing
        self.teamclawService = teamclawService
    }

    public var body: some Scene {
        WindowGroup("Session", id: "session-detail", for: String.self) { $sessionId in
            DetachedSessionRoot(
                sessionId: sessionId,
                pairing: pairing,
                teamclawService: teamclawService
            )
            .frame(minWidth: 540, minHeight: 480)
        }
    }
}

private struct DetachedSessionRoot: View {
    let sessionId: String?
    let pairing: PairingManager
    let teamclawService: TeamclawService

    @Query private var sessions: [CollabSession]

    var body: some View {
        if let sessionId, let session = sessions.first(where: { $0.sessionId == sessionId }) {
            // Detached windows currently don't own an MQTT connection, so
            // AgentDetailViewModel won't be wired here and only the collab
            // message fallback is shown. TODO: share MQTT from MainWindow or
            // spin up a second connection for this window.
            SessionDetailView(
                session: session,
                teamclawService: teamclawService,
                actorId: pairing.deviceId,
                mqtt: nil,
                deviceId: pairing.deviceId,
                peerId: "mac-detached-\(UUID().uuidString.prefix(6))"
            )
        } else {
            ContentUnavailableView(
                "Session not found",
                systemImage: "exclamationmark.triangle",
                description: Text("This session may have been deleted or hasn't synced yet.")
            )
        }
    }
}
