import XCTest
@testable import AnLuongMeeting

final class MeetingDetailActionTests: XCTestCase {
    func testHeaderActionsUseOneUnifiedMenuOrder() {
        XCTAssertEqual(
            MeetingDetailAction.allCases,
            [.regenerateTranscript, .regenerateNote, .regenerateBoth, .rename, .delete]
        )
    }
}
