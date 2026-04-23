import Foundation

public protocol TaskRepository: Sendable {
    func listTasks(teamID: String) async throws -> [TaskRecord]
    func createTask(teamID: String, input: TaskCreateInput) async throws -> TaskRecord
    func updateTask(taskID: String, input: TaskUpdateInput) async throws -> TaskRecord
    func setArchived(taskID: String, archived: Bool) async throws -> TaskRecord
}
