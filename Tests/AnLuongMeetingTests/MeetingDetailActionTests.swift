import XCTest
@testable import AnLuongMeeting

final class MeetingDetailActionTests: XCTestCase {
    func testHeaderActionsUseOneUnifiedMenuOrder() {
        XCTAssertEqual(
            MeetingDetailAction.allCases,
            [.editNote, .regenerateTranscript, .regenerateNote, .regenerateBoth, .exportPDF, .copyPlainText, .rename, .delete]
        )
    }

    func testPlainTextStripsMarkdownSyntax() {
        let blocks = AnLuongMarkdown.parse("# Title\n\n- One\n- Two")
        XCTAssertEqual(AnLuongMarkdown.plainText(blocks), "Title\n\n• One\n• Two")
    }

    func testPDFRenderProducesValidPDFData() {
        let blocks = AnLuongMarkdown.parse("# Title\n\nSome body text.")
        let data = AnLuongMarkdownPDF.render(title: "Meeting", blocks: blocks)
        XCTAssertGreaterThan(data.count, 0)
        XCTAssertEqual(data.prefix(4), Data("%PDF".utf8))
    }
}
