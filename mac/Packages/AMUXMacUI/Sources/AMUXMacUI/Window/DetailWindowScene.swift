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

    @Environment(SharedConnection.self) private var shared
    @Query private var sessions: [CollabSession]

    var body: some View {
        Group {
            if let sessionId, let session = sessions.first(where: { $0.sessionId == sessionId }) {
                // Reuse the process-wide MQTT session so the agent-event feed
                // and prompt composer work in detached windows the same way
                // they do in the main window.
                SessionDetailView(
                    session: session,
                    teamclawService: teamclawService,
                    actorId: pairing.deviceId,
                    mqtt: shared.mqtt,
                    deviceId: pairing.deviceId,
                    peerId: shared.peerId
                )
            } else {
                ContentUnavailableView(
                    "Session not found",
                    systemImage: "exclamationmark.triangle",
                    description: Text("This session may have been deleted or hasn't synced yet.")
                )
            }
        }
        // Opening a detached window before the main window has connected
        // would otherwise leave the session dark; kick the shared connection
        // so a solo detached window still wires up MQTT.
        .task { await shared.connectIfNeeded(pairing: pairing) }
    }
}
