import XCTest
@testable import AnLuongMeeting

final class TranscriptSectionsTests: XCTestCase {
    func testGroupsInlineSpeakerFormatIntoOneSectionPerTurn() {
        let transcript = """
        SPEAKER_0: Alo.
        SPEAKER_1: Hello anh.
        SPEAKER_0: Anh Trường An bây giờ đang làm ở đâu ta?
        """

        let sections = transcriptSections(from: transcript)

        XCTAssertEqual(sections.map(\.speaker), ["SPEAKER_0", "SPEAKER_1", "SPEAKER_0"])
        XCTAssertEqual(sections.map(\.text), [
            "Alo.",
            "Hello anh.",
            "Anh Trường An bây giờ đang làm ở đâu ta?"
        ])
    }

    func testMergesConsecutiveLinesFromTheSameSpeakerIntoOneSection() {
        let transcript = """
        SPEAKER_0: First line.
        SPEAKER_0: Second line.
        SPEAKER_1: Reply.
        """

        let sections = transcriptSections(from: transcript)

        XCTAssertEqual(sections.count, 2)
        XCTAssertEqual(sections[0].speaker, "SPEAKER_0")
        XCTAssertEqual(sections[0].text, "First line.\nSecond line.")
        XCTAssertEqual(sections[1].text, "Reply.")
    }

    func testHandlesLabelOnItsOwnLineFollowedByContentLines() {
        let transcript = """
        SPEAKER_00:
        Some content here.
        More content.
        """

        let sections = transcriptSections(from: transcript)

        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(sections[0].speaker, "SPEAKER_00")
        XCTAssertEqual(sections[0].text, "Some content here.\nMore content.")
    }

    func testDoesNotMistakeAColonInsideContentForASpeakerLabel() {
        let transcript = "SPEAKER_0: Ví dụ: đây là nội dung."

        let sections = transcriptSections(from: transcript)

        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(sections[0].text, "Ví dụ: đây là nội dung.")
    }
}
