import Foundation
import SwiftData
import AMUXCore

@Observable
@MainActor
public final class CollabSessionViewModel {
    public var messages: [SessionMessage] = []
    public var workItems: [WorkItem] = []
    public var session: CollabSession

    private var teamclawService: TeamclawService?
    private var listenerTask: Task<Void, Never>?
    private var actorId: String = ""

    public init(session: CollabSession) {
        self.session = session
    }

    public func start(teamclawService: TeamclawService, actorId: String, modelContext: ModelContext) {
        self.teamclawService = teamclawService
        self.actorId = actorId
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

                let wiDescriptor = FetchDescriptor<WorkItem>(
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
            content: text,
            actorId: actorId
        )
    }
}
