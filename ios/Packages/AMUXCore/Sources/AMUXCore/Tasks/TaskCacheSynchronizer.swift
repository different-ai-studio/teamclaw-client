import Foundation
import SwiftData

@MainActor
public enum TaskCacheSynchronizer {
    public static func upsert(_ tasks: [TaskRecord], modelContext: ModelContext) {
        for task in tasks {
            upsert(task, modelContext: modelContext)
        }

        try? modelContext.save()
    }

    public static func upsert(_ task: TaskRecord, modelContext: ModelContext) {
        let descriptor = FetchDescriptor<SessionTask>(
            predicate: #Predicate { $0.taskId == task.id }
        )

        if let existing = try? modelContext.fetch(descriptor).first {
            existing.workspaceId = task.workspaceID
            existing.title = task.title
            existing.taskDescription = task.description
            existing.status = task.status
            existing.createdBy = task.createdByActorID
            existing.createdAt = task.createdAt
            existing.archived = task.archived
        } else {
            modelContext.insert(
                SessionTask(
                    taskId: task.id,
                    sessionId: "",
                    workspaceId: task.workspaceID,
                    title: task.title,
                    taskDescription: task.description,
                    status: task.status,
                    parentTaskId: "",
                    createdBy: task.createdByActorID,
                    createdAt: task.createdAt,
                    archived: task.archived
                )
            )
        }
    }
}
