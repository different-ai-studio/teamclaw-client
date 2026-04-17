import XCTest
@testable import AMUXMacUI

final class AMUXMacUITests: XCTestCase {
    func testBuildVersion() {
        XCTAssertEqual(AMUXMacUI.buildVersion, "0.1.0")
    }
}
