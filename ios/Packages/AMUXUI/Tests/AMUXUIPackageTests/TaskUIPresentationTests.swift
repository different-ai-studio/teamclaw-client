import Testing
@testable import AMUXUI

@Suite("Task UI presentation")
struct TaskUIPresentationTests {
    @Test("task-backed UI presents ideas to users")
    func taskBackedUIPresentsIdeas() {
        #expect(TaskUIPresentation.singularTitle == "Idea")
        #expect(TaskUIPresentation.pluralTitle == "Ideas")
        #expect(TaskUIPresentation.systemImage == "lightbulb")
    }
}
