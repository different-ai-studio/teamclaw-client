import XCTest
import AMUXCore
@testable import AMUXMacUI

final class IdeaDetailViewTests: XCTestCase {
    func testStatusDisplayForKnownValues() {
        XCTAssertEqual(IdeaDetailView.statusDisplay(for: "open"), "Open")
        XCTAssertEqual(IdeaDetailView.statusDisplay(for: "in_progress"), "In Progress")
        XCTAssertEqual(IdeaDetailView.statusDisplay(for: "done"), "Done")
    }

    func testStatusDisplayForUnknownValue() {
        XCTAssertEqual(IdeaDetailView.statusDisplay(for: "archived"), "archived")
        XCTAssertEqual(IdeaDetailView.statusDisplay(for: ""), "Unknown")
    }
}
