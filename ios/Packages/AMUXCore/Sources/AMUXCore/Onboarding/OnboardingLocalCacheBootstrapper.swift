import Foundation
import SwiftData

public enum OnboardingLocalCacheBootstrapper {
    public static func prime(createdTeam: CreatedTeam, modelContext: ModelContext) {
        upsertMember(actorID: createdTeam.memberActorID, modelContext: modelContext)
        upsertWorkspace(
            workspaceID: createdTeam.workspaceID,
            name: createdTeam.workspaceName,
            modelContext: modelContext
        )
        try? modelContext.save()
    }

    public static func ensureWorkspaceExists(team: TeamSummary, modelContext: ModelContext) {
        let descriptor = FetchDescriptor<Workspace>()
        let existing = (try? modelContext.fetch(descriptor)) ?? []
        guard existing.isEmpty else { return }

        modelContext.insert(
            Workspace(
                workspaceId: "local-\(team.id)-general",
                path: "",
                displayName: "General"
            )
        )
        try? modelContext.save()
    }

    private static func upsertMember(actorID: String, modelContext: ModelContext) {
        let descriptor = FetchDescriptor<CachedActor>(predicate: #Predicate { $0.actorId == actorID })
        if let existing = try? modelContext.fetch(descriptor).first {
            existing.displayName = existing.displayName.isEmpty ? "You" : existing.displayName
            existing.teamRole = "owner"
            return
        }

        modelContext.insert(
            CachedActor(
                actorId: actorID,
                teamId: "",
                actorType: "member",
                displayName: "You",
                memberStatus: "active",
                teamRole: "owner"
            )
        )
    }

    private static func upsertWorkspace(workspaceID: String, name: String, modelContext: ModelContext) {
        let descriptor = FetchDescriptor<Workspace>(predicate: #Predicate { $0.workspaceId == workspaceID })
        if let existing = try? modelContext.fetch(descriptor).first {
            existing.displayName = name
            return
        }

        modelContext.insert(
            Workspace(
                workspaceId: workspaceID,
                path: "",
                displayName: name
            )
        )
    }
}
