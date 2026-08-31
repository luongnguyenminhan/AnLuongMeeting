import XCTest
@testable import AnLuongMeeting

final class AnswerTagStreamBufferTests: XCTestCase {
    func testBuffersEverythingBeforeTheOpeningTag() {
        var buffer = AnswerTagStreamBuffer()
        XCTAssertEqual(buffer.append("Let me think about this. "), "")
        XCTAssertEqual(buffer.append("Wait, actually reconsidering. "), "")
        XCTAssertEqual(buffer.append("<answer>Hello"), "Hello")
    }

    func testEmitsIncrementallyAsDeltasArrive() {
        var buffer = AnswerTagStreamBuffer()
        _ = buffer.append("<answer>")
        XCTAssertEqual(buffer.append("Hello"), "Hello")
        XCTAssertEqual(buffer.append(" world"), " world")
    }

    func testStopsEmittingAtTheClosingTag() {
        var buffer = AnswerTagStreamBuffer()
        _ = buffer.append("<answer>")
        XCTAssertEqual(buffer.append("Hello</answer>"), "Hello")
        XCTAssertTrue(buffer.isDone)
        XCTAssertEqual(buffer.append("more junk after"), "")
    }

    func testHoldsBackAPossiblePartialClosingTagUntilResolved() {
        var buffer = AnswerTagStreamBuffer()
        _ = buffer.append("<answer>")
        // "</ans" could be the start of "</answer>" — must not be emitted yet.
        XCTAssertEqual(buffer.append("Hello</ans"), "Hello")
        // It resolves into a real closing tag — no leaked "</ans" fragment.
        XCTAssertEqual(buffer.append("wer>"), "")
        XCTAssertTrue(buffer.isDone)
    }

    func testAPartialTagThatNeverCompletesIsEventuallyEmittedAsText() {
        var buffer = AnswerTagStreamBuffer()
        _ = buffer.append("<answer>")
        // "</ans" turns out NOT to be a closing tag after all.
        XCTAssertEqual(buffer.append("Hello</ans"), "Hello")
        XCTAssertEqual(buffer.append("wich, not a tag"), "</answich, not a tag")
    }

    func testFinishFallsBackToRawTextWhenNoOpeningTagWasEverSeen() {
        var buffer = AnswerTagStreamBuffer()
        _ = buffer.append("  Just a plain reply, no tags.  ")
        XCTAssertEqual(buffer.finish(), "Just a plain reply, no tags.")
    }

    func testFinishReturnsEmptyWhenAlreadyDone() {
        var buffer = AnswerTagStreamBuffer()
        _ = buffer.append("<answer>Hello</answer>")
        XCTAssertTrue(buffer.isDone)
        XCTAssertEqual(buffer.finish(), "")
    }
}
