import Foundation
import SwiftData
import AMUXCore

@Observable
@MainActor
public final class SessionViewModel {
    public var messages: [SessionMessage] = []
    public var ideas: [SessionIdea] = []
    public var session: Session

    private var teamclawService: TeamclawService?
    private var currentActorID: String?
    private var modelContext: ModelContext?
    private var listenerTask: Task<Void, Never>?

    public init(session: Session) {
        self.session = session
    }

    public func start(teamclawService: TeamclawService?, currentActorID: String?, modelContext: ModelContext) {
        self.teamclawService = teamclawService
        self.currentActorID = currentActorID
        self.modelContext = modelContext
        teamclawService?.subscribeToSession(session.sessionId)

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

                let ideaDescriptor = FetchDescriptor<SessionIdea>(
                    predicate: #Predicate { $0.sessionId == sid },
                    sortBy: [SortDescriptor(\.createdAt)]
                )
                self.ideas = (try? modelContext.fetch(ideaDescriptor)) ?? []

                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    public func stop() {
        listenerTask?.cancel()
        listenerTask = nil
    }

    public func sendMessage(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if let teamclawService {
            teamclawService.sendMessage(
                sessionId: session.sessionId,
                content: trimmed
            )
            return
        }

        guard let currentActorID else { return }

        guard let modelContext else { return }

        let message = SessionMessage(
            messageId: UUID().uuidString,
            sessionId: session.sessionId,
            senderActorId: currentActorID,
            kind: "text",
            content: trimmed,
            createdAt: .now
        )
        modelContext.insert(message)
        session.lastMessagePreview = trimmed
        session.lastMessageAt = message.createdAt
        try? modelContext.save()
        messages.append(message)
    }
}
