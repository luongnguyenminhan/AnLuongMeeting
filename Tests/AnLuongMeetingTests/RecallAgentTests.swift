import XCTest
@testable import AnLuongMeeting

final class RecallAgentTests: XCTestCase {
    func testCosineSimilarityIsOneForIdenticalVectors() {
        XCTAssertEqual(RecallAgent.cosineSimilarity([1, 0, 0], [1, 0, 0]), 1.0, accuracy: 0.0001)
    }

    func testCosineSimilarityIsZeroForOrthogonalVectors() {
        XCTAssertEqual(RecallAgent.cosineSimilarity([1, 0], [0, 1]), 0.0, accuracy: 0.0001)
    }

    func testCosineSimilarityHandlesZeroVectorWithoutCrashing() {
        XCTAssertEqual(RecallAgent.cosineSimilarity([0, 0], [1, 1]), 0.0)
    }

    func testTopMatchesRanksClosestVectorsFirst() {
        let candidates: [(id: String, vector: [Double])] = [
            (id: "far", vector: [0, 1]),
            (id: "closest", vector: [1, 0]),
            (id: "medium", vector: [0.7, 0.7])
        ]

        let ranked = RecallAgent.topMatches(query: [1, 0], candidates: candidates, limit: 2)

        XCTAssertEqual(ranked, ["closest", "medium"])
    }

    func testTopMatchesRespectsLimit() {
        let candidates: [(id: String, vector: [Double])] = [
            (id: "a", vector: [1, 0]),
            (id: "b", vector: [0.9, 0.1]),
            (id: "c", vector: [0.1, 0.9])
        ]

        XCTAssertEqual(RecallAgent.topMatches(query: [1, 0], candidates: candidates, limit: 1), ["a"])
    }

    func testRenderHistoryIsEmptyWithNoPriorTurns() {
        XCTAssertEqual(RecallAgent.renderHistory([]), "")
    }

    func testRenderHistoryIncludesQuestionAndAnswerPairs() {
        let history = [RecallTurn(question: "What did we decide?", answerText: "You decided X.")]
        XCTAssertEqual(
            RecallAgent.renderHistory(history),
            "CONVERSATION SO FAR:\nUser: What did we decide?\nAssistant: You decided X.\n\n"
        )
    }

    func testRenderHistoryKeepsOnlyTheMostRecentTurns() {
        let history = (0..<5).map { RecallTurn(question: "Q\($0)", answerText: "A\($0)") }
        let rendered = RecallAgent.renderHistory(history)

        XCTAssertFalse(rendered.contains("Q0"))
        XCTAssertFalse(rendered.contains("Q1"))
        XCTAssertTrue(rendered.contains("Q2"))
        XCTAssertTrue(rendered.contains("Q4"))
    }
}
