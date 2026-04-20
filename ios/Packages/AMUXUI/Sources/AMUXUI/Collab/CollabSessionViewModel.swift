import Foundation
import SwiftData
import AMUXCore

@Observable
@MainActor
public final class SessionViewModel {
    public var messages: [SessionMessage] = []
    public var workItems: [SessionTask] = []
    public var session: Session

    private var teamclawService: TeamclawService?
    private var listenerTask: Task<Void, Never>?

    public init(session: Session) {
        self.session = session
    }

    public func start(teamclawService: TeamclawService, modelContext: ModelContext) {
        self.teamclawService = teamclawService
        teamclawService.subscribeToSession(session.sessionId)

        listenerTask?.cancel()
        listenerTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let sid = self.session.sessionId
                let msgDescriptor = FetchDescriptor<SessionMessage>(
                    predicate: #Predicate { $0.sessionId == sid },
                    sortBy: [SortDescriptor(\.createdAt)]
                )
                self.messages = (try? modelContext.fetch(msgDescriptor)) ?? []

                let wiDescriptor = FetchDescriptor<SessionTask>(
                    predicate: #Predicate { $0.sessionId == sid },
                    sortBy: [SortDescriptor(\.createdAt)]
                )
                self.workItems = (try? modelContext.fetch(wiDescriptor)) ?? []

                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    public func stop() {
        listenerTask?.cancel()
        listenerTask = nil
    }

    public func sendMessage(_ text: String) {
        teamclawService?.sendMessage(
            sessionId: session.sessionId,
            content: text
        )
    }
}
