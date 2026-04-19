import SwiftUI
import SwiftData
import AMUXCore

public struct TaskEditorWindowScene: Scene {
    let teamclawService: TeamclawService

    public init(teamclawService: TeamclawService) {
        self.teamclawService = teamclawService
    }

    public var body: some Scene {
        WindowGroup(id: "amux.taskEditor", for: TaskEditorInput.self) { $input in
            if let input {
                TaskEditorScene(input: input, teamclawService: teamclawService)
            }
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 520, height: 400)
    }
}

private struct TaskEditorScene: View {
    let input: TaskEditorInput
    let teamclawService: TeamclawService

    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        TaskEditorView(input: input, teamclawService: teamclawService) {
            dismissWindow(id: "amux.taskEditor")
        }
        .modelContainer(for: [WorkItem.self, Agent.self, CollabSession.self, SessionMessage.self, Member.self, AgentEvent.self, Workspace.self])
    }
}
