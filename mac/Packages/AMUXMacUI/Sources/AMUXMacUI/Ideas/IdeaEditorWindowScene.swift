import SwiftUI
import SwiftData
import AMUXCore

public struct IdeaEditorWindowScene: Scene {
    let teamclawService: TeamclawService

    public init(teamclawService: TeamclawService) {
        self.teamclawService = teamclawService
    }

    public var body: some Scene {
        WindowGroup(id: "amux.ideaEditor", for: IdeaEditorInput.self) { $input in
            if let input {
                IdeaEditorScene(input: input, teamclawService: teamclawService)
            }
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 520, height: 400)
    }
}

private struct IdeaEditorScene: View {
    let input: IdeaEditorInput
    let teamclawService: TeamclawService

    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        IdeaEditorView(input: input, teamclawService: teamclawService) {
            dismissWindow(id: "amux.ideaEditor")
        }
        .appAppearance()
    }
}
