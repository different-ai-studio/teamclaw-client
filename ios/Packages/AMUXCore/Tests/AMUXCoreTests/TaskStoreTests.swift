import Foundation
import SwiftData
import Testing
@testable import AMUXCore

@Suite("TaskStore")
struct TaskStoreTests {

    @MainActor
    @Test("reload partitions active and archived tasks and mirrors them locally")
    func reloadPartitionsAndMirrorsTasks() async throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        let repository = InMemoryTaskRepository(
            tasks: [
                TaskRecord(
                    id: "task-open",
                    teamID: "team-1",
                    workspaceID: "workspace-1",
                    createdByActorID: "member-1",
                    title: "Open task",
                    description: "Ship the open task",
                    status: "open",
                    archived: false,
                    createdAt: .distantPast,
                    updatedAt: .distantPast
                ),
                TaskRecord(
                    id: "task-archived",
                    teamID: "team-1",
                    workspaceID: "workspace-2",
                    createdByActorID: "member-2",
                    title: "Archived task",
                    description: "Already done",
                    status: "done",
                    archived: true,
                    createdAt: .now,
                    updatedAt: .now
                ),
            ]
        )
        let store = TaskStore(teamID: "team-1", repository: repository, modelContext: context)

        await store.reload()

        #expect(store.tasks.map(\.id) == ["task-open"])
        #expect(store.archivedTasks.map(\.id) == ["task-archived"])

        let cached = try context.fetch(FetchDescriptor<SessionTask>(sortBy: [SortDescriptor(\.taskId)]))
        #expect(cached.map(\.taskId) == ["task-archived", "task-open"])
        #expect(cached.first(where: { $0.taskId == "task-open" })?.title == "Open task")
        #expect(cached.first(where: { $0.taskId == "task-archived" })?.archived == true)
    }

    @MainActor
    @Test("create update and archive keep remote state and local cache aligned")
    func createUpdateAndArchiveStayAligned() async throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        let repository = InMemoryTaskRepository(tasks: [])
        let store = TaskStore(teamID: "team-1", repository: repository, modelContext: context)

        await store.createTask(
            title: "First task",
            description: "Initial description",
            workspaceID: "workspace-1"
        )

        #expect(store.tasks.map(\.title) == ["First task"])
        #expect(await repository.recordedCreatedInputs().map(\.title) == ["First task"])

        let createdID = try #require(store.tasks.first?.id)

        await store.updateTask(
            taskID: createdID,
            title: "Renamed task",
            description: "Edited description",
            status: "in_progress",
            workspaceID: "workspace-2"
        )

        let updated = try #require(store.tasks.first)
        #expect(updated.title == "Renamed task")
        #expect(updated.description == "Edited description")
        #expect(updated.status == "in_progress")
        #expect(updated.workspaceID == "workspace-2")

        await store.setArchived(taskID: createdID, archived: true)

        #expect(store.tasks.isEmpty)
        #expect(store.archivedTasks.map(\.id) == [createdID])
        let archiveInputs = await repository.recordedArchiveInputs()
        #expect(archiveInputs.count == 1)
        #expect(archiveInputs.first?.0 == createdID)
        #expect(archiveInputs.first?.1 == true)

        let cached = try context.fetch(FetchDescriptor<SessionTask>())
        #expect(cached.count == 1)
        #expect(cached.first?.taskId == createdID)
        #expect(cached.first?.archived == true)
        #expect(cached.first?.workspaceId == "workspace-2")
    }

    @MainActor
    @Test("general workspace stays empty in task records")
    func generalWorkspaceStaysEmpty() async throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        let repository = InMemoryTaskRepository(tasks: [])
        let store = TaskStore(teamID: "team-1", repository: repository, modelContext: context)

        await store.createTask(
            title: "General task",
            description: "No explicit workspace",
            workspaceID: ""
        )

        let created = try #require(store.tasks.first)
        #expect(created.workspaceID.isEmpty)
        #expect(await repository.recordedCreatedInputs().first?.workspaceID == "")
    }
}

private actor InMemoryTaskRepository: TaskRepository {
    private var tasksByID: [String: TaskRecord]
    private var createdInputs: [TaskCreateInput] = []
    private var archiveInputs: [(String, Bool)] = []

    init(tasks: [TaskRecord]) {
        self.tasksByID = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
    }

    func listTasks(teamID: String) async throws -> [TaskRecord] {
        tasksByID.values
            .filter { $0.teamID == teamID }
            .sorted { lhs, rhs in
                if lhs.createdAt == rhs.createdAt {
                    return lhs.id < rhs.id
                }
                return lhs.createdAt < rhs.createdAt
            }
    }

    func createTask(teamID: String, input: TaskCreateInput) async throws -> TaskRecord {
        createdInputs.append(input)
        let task = TaskRecord(
            id: "task-\(createdInputs.count)",
            teamID: teamID,
            workspaceID: input.workspaceID,
            createdByActorID: "member-1",
            title: input.title,
            description: input.description,
            status: "open",
            archived: false,
            createdAt: .now,
            updatedAt: .now
        )
        tasksByID[task.id] = task
        return task
    }

    func updateTask(taskID: String, input: TaskUpdateInput) async throws -> TaskRecord {
        guard var existing = tasksByID[taskID] else {
            throw InMemoryError.missingTask
        }
        existing.workspaceID = input.workspaceID
        existing.title = input.title
        existing.description = input.description
        existing.status = input.status
        existing.updatedAt = .now
        tasksByID[taskID] = existing
        return existing
    }

    func setArchived(taskID: String, archived: Bool) async throws -> TaskRecord {
        archiveInputs.append((taskID, archived))
        guard var existing = tasksByID[taskID] else {
            throw InMemoryError.missingTask
        }
        existing.archived = archived
        existing.updatedAt = .now
        tasksByID[taskID] = existing
        return existing
    }

    func recordedCreatedInputs() -> [TaskCreateInput] {
        createdInputs
    }

    func recordedArchiveInputs() -> [(String, Bool)] {
        archiveInputs
    }

    enum InMemoryError: Error {
        case missingTask
    }
}

@MainActor
private func makeInMemoryContainer() throws -> ModelContainer {
    let schema = Schema(versionedSchema: AMUXSchemaV1.self)
    let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    return try ModelContainer(for: schema, configurations: configuration)
}
