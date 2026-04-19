import XCTest
import AMUXCore
@testable import AMUXMacUI

final class TaskDetailViewTests: XCTestCase {
    func testStatusDisplayForKnownValues() {
        XCTAssertEqual(TaskDetailView.statusDisplay(for: "open"), "Open")
        XCTAssertEqual(TaskDetailView.statusDisplay(for: "in_progress"), "In Progress")
        XCTAssertEqual(TaskDetailView.statusDisplay(for: "done"), "Done")
    }

    func testStatusDisplayForUnknownValue() {
        XCTAssertEqual(TaskDetailView.statusDisplay(for: "archived"), "archived")
        XCTAssertEqual(TaskDetailView.statusDisplay(for: ""), "Unknown")
    }
}
