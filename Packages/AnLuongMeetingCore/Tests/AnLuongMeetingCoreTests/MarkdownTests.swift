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

    func testPlainTextStripsMarkdownSyntax() {
        let blocks: [MarkdownBlock] = [
            .heading(level: 1, text: "Meeting"),
            .paragraph("Summary text."),
            .unorderedList(["First", "Second"]),
            .orderedList(["Step one", "Step two"]),
            .quote("Quoted line"),
            .divider
        ]
        XCTAssertEqual(Markdown.plainText(blocks), """
        Meeting

        Summary text.

        • First
        • Second

        1. Step one
        2. Step two

        Quoted line
        """)
    }
}
