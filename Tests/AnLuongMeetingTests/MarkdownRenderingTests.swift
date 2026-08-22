import XCTest
@testable import AnLuongMeeting

final class MarkdownRenderingTests: XCTestCase {
    func testParsesMeetingNoteBlocks() {
        let markdown = """
        # CẬP NHẬT DỮ LIỆU VÀO CATALOG

        ## Thông tin chung
        - **Ngày họp**: 22/08/2026
        - Chủ đề: Append hay override

        ## Quyết định
        1. Dùng append cho dữ liệu mới.
        2. Dùng override khi cần thay thế hoàn toàn.

        > Cần xác nhận schema trước khi thực hiện.

        ```sql
        SELECT * FROM catalog;
        ```
        """

        XCTAssertEqual(
            AnLuongMarkdown.parse(markdown),
            [
                .heading(level: 1, text: "CẬP NHẬT DỮ LIỆU VÀO CATALOG"),
                .heading(level: 2, text: "Thông tin chung"),
                .unorderedList([
                    "**Ngày họp**: 22/08/2026",
                    "Chủ đề: Append hay override"
                ]),
                .heading(level: 2, text: "Quyết định"),
                .orderedList([
                    "Dùng append cho dữ liệu mới.",
                    "Dùng override khi cần thay thế hoàn toàn."
                ]),
                .quote("Cần xác nhận schema trước khi thực hiện."),
                .code("SELECT * FROM catalog;")
            ]
        )
    }

    func testPreservesParagraphsAndDividers() {
        let markdown = """
        Một dòng đầu tiên
        nối tiếp cùng một đoạn.

        ---

        Đoạn cuối.
        """

        XCTAssertEqual(
            AnLuongMarkdown.parse(markdown),
            [
                .paragraph("Một dòng đầu tiên nối tiếp cùng một đoạn."),
                .divider,
                .paragraph("Đoạn cuối.")
            ]
        )
    }

    func testIgnoresEmptyMarkdown() {
        XCTAssertTrue(AnLuongMarkdown.parse("\n  \n") .isEmpty)
    }
}
