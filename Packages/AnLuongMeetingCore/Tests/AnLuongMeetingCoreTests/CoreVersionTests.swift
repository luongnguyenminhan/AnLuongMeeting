import XCTest
@testable import AnLuongMeetingCore

final class CoreVersionTests: XCTestCase {
    func testCoreModuleIsLoadable() {
        XCTAssertEqual(AnLuongMeetingCoreVersion.current, "1")
    }
}
