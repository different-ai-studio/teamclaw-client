import Foundation
import Observation
import SwiftData

@Observable
@MainActor
public final class TaskStore {
    public private(set) var tasks: [TaskRecord] = []
    public private(set) var archivedTasks: [TaskRecord] = []
    public private(set) var isLoading = false
    public var errorMessage: String?

    private let teamID: String
    private let repository: any TaskRepository
    private let modelContext: ModelContext

    public init(teamID: String, repository: any TaskRepository, modelContext: ModelContext) {
        self.teamID = teamID
        self.repository = repository
        self.modelContext = modelContext
    }

    public func reload() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            let remoteTasks = try await repository.listTasks(teamID: teamID)
            apply(remoteTasks)
            TaskCacheSynchronizer.upsert(remoteTasks, modelContext: modelContext)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    public func createTask(title: String, description: String, workspaceID: String) async -> Bool {
        do {
            let created = try await repository.createTask(
                teamID: teamID,
                input: TaskCreateInput(
                    title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                    description: description.trimmingCharacters(in: .whitespacesAndNewlines),
                    workspaceID: workspaceID
                )
            )
            merge(created)
            TaskCacheSynchronizer.upsert(created, modelContext: modelContext)
            try? modelContext.save()
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    public func updateTask(
        taskID: String,
        title: String,
        description: String,
        status: String,
        workspaceID: String
    ) async -> Bool {
        do {
            let updated = try await repository.updateTask(
                taskID: taskID,
                input: TaskUpdateInput(
                    title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                    description: description.trimmingCharacters(in: .whitespacesAndNewlines),
                    status: status,
                    workspaceID: workspaceID
                )
            )
            merge(updated)
            TaskCacheSynchronizer.upsert(updated, modelContext: modelContext)
            try? modelContext.save()
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    public func setArchived(taskID: String, archived: Bool) async -> Bool {
        do {
            let updated = try await repository.setArchived(taskID: taskID, archived: archived)
            merge(updated)
            TaskCacheSynchronizer.upsert(updated, modelContext: modelContext)
            try? modelContext.save()
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    public func task(id: String) -> TaskRecord? {
        (tasks + archivedTasks).first(where: { $0.id == id })
    }

    private func apply(_ records: [TaskRecord]) {
        let sorted = sort(records)
        tasks = sorted.filter { !$0.archived }
        archivedTasks = sorted.filter(\.archived)
    }

    private func merge(_ record: TaskRecord) {
        var all = Dictionary(uniqueKeysWithValues: (tasks + archivedTasks).map { ($0.id, $0) })
        all[record.id] = record
        apply(Array(all.values))
    }

    private func sort(_ records: [TaskRecord]) -> [TaskRecord] {
        records.sorted { lhs, rhs in
            if lhs.updatedAt == rhs.updatedAt {
                return lhs.createdAt > rhs.createdAt
            }
            return lhs.updatedAt > rhs.updatedAt
        }
    }
}
