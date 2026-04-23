import Foundation
import Supabase

public enum TaskRepositoryError: LocalizedError {
    case missingTitle
    case emptyResponse(String)

    public var errorDescription: String? {
        switch self {
        case .missingTitle:
            return "Title is required."
        case .emptyResponse(let functionName):
            return "\(functionName) returned no rows."
        }
    }
}

public actor SupabaseTaskRepository: TaskRepository {
    private let client: SupabaseClient

    public init(configuration: SupabaseProjectConfiguration) {
        self.client = SupabaseClient(
            supabaseURL: configuration.url,
            supabaseKey: configuration.publishableKey
        )
    }

    public init() throws {
        let configuration = try SupabaseProjectConfiguration.fromMainBundle()
        self.client = SupabaseClient(
            supabaseURL: configuration.url,
            supabaseKey: configuration.publishableKey
        )
    }

    public func listTasks(teamID: String) async throws -> [TaskRecord] {
        let rows: [TaskRow] = try await client
            .from("tasks")
            .select(
                """
                id,
                team_id,
                workspace_id,
                created_by_actor_id,
                title,
                description,
                status,
                archived,
                created_at,
                updated_at
                """
            )
            .eq("team_id", value: teamID)
            .order("updated_at", ascending: false)
            .execute()
            .value

        return rows.map(\.record)
    }

    public func createTask(teamID: String, input: TaskCreateInput) async throws -> TaskRecord {
        let title = input.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let workspaceID = normalizedWorkspaceID(input.workspaceID)

        guard !title.isEmpty else {
            throw TaskRepositoryError.missingTitle
        }

        let rows: [TaskRow] = try await client
            .rpc(
                "create_task",
                params: CreateTaskParams(
                    teamID: teamID,
                    workspaceID: workspaceID,
                    title: title,
                    description: input.description
                )
            )
            .execute()
            .value

        guard let row = rows.first else {
            throw TaskRepositoryError.emptyResponse("create_task")
        }

        return row.record
    }

    public func updateTask(taskID: String, input: TaskUpdateInput) async throws -> TaskRecord {
        let title = input.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let workspaceID = normalizedWorkspaceID(input.workspaceID)

        guard !title.isEmpty else {
            throw TaskRepositoryError.missingTitle
        }

        let rows: [TaskRow] = try await client
            .rpc(
                "update_task",
                params: UpdateTaskParams(
                    taskID: taskID,
                    workspaceID: workspaceID,
                    title: title,
                    description: input.description,
                    status: input.status
                )
            )
            .execute()
            .value

        guard let row = rows.first else {
            throw TaskRepositoryError.emptyResponse("update_task")
        }

        return row.record
    }

    public func setArchived(taskID: String, archived: Bool) async throws -> TaskRecord {
        let rows: [TaskRow] = try await client
            .rpc(
                "archive_task",
                params: ArchiveTaskParams(taskID: taskID, archived: archived)
            )
            .execute()
            .value

        guard let row = rows.first else {
            throw TaskRepositoryError.emptyResponse("archive_task")
        }

        return row.record
    }

    private func normalizedWorkspaceID(_ workspaceID: String) -> String? {
        let trimmed = workspaceID.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private struct CreateTaskParams: Encodable {
    let teamID: String
    let workspaceID: String?
    let title: String
    let description: String

    enum CodingKeys: String, CodingKey {
        case teamID = "p_team_id"
        case workspaceID = "p_workspace_id"
        case title = "p_title"
        case description = "p_description"
    }
}

private struct UpdateTaskParams: Encodable {
    let taskID: String
    let workspaceID: String?
    let title: String
    let description: String
    let status: String

    enum CodingKeys: String, CodingKey {
        case taskID = "p_task_id"
        case workspaceID = "p_workspace_id"
        case title = "p_title"
        case description = "p_description"
        case status = "p_status"
    }
}

private struct ArchiveTaskParams: Encodable {
    let taskID: String
    let archived: Bool

    enum CodingKeys: String, CodingKey {
        case taskID = "p_task_id"
        case archived = "p_archived"
    }
}

private struct TaskRow: Decodable, Sendable {
    let id: String
    let teamID: String
    let workspaceID: String?
    let createdByActorID: String
    let title: String
    let description: String
    let status: String
    let archived: Bool
    let createdAt: Date
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case teamID = "team_id"
        case workspaceID = "workspace_id"
        case createdByActorID = "created_by_actor_id"
        case title
        case description
        case status
        case archived
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    var record: TaskRecord {
        TaskRecord(
            id: id,
            teamID: teamID,
            workspaceID: workspaceID ?? "",
            createdByActorID: createdByActorID,
            title: title,
            description: description,
            status: status,
            archived: archived,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}
