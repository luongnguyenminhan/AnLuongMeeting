import XCTest
@testable import AnLuongMeetingCore

final class MarkdownTests: XCTestCase {
    func testParsesMeetingNoteBlocks() {
        let blocks = Markdown.parse("""
        # Meeting

        ## Topics
        - **One**
        1. Two

        > Quote

        ```swift
        let value = 1
        ```
        """)
        XCTAssertEqual(blocks, [
            .heading(level: 1, text: "Meeting"),
            .heading(level: 2, text: "Topics"),
            .unorderedList(["**One**"]),
            .orderedList(["Two"]),
            .quote("Quote"),
            .code("let value = 1")
        ])
    }

    func testEmptyMarkdownIsEmpty() {
        XCTAssertTrue(Markdown.parse("\n  \n").isEmpty)
    }
}
