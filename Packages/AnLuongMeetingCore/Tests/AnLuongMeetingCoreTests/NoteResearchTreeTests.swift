import XCTest
@testable import AnLuongMeetingCore

final class NoteResearchTreeTests: XCTestCase {
    func testClassifyGeminiResponseReturnsRateLimitedFor429WithRetryAfter() {
        let response = HTTPURLResponse(
            url: URL(string: "https://example.com")!,
            statusCode: 429,
            httpVersion: nil,
            headerFields: ["Retry-After": "5"]
        )!

        XCTAssertEqual(classifyGeminiResponse(response, errorBody: nil), .rateLimited(retryAfter: 5))
    }

    func testClassifyGeminiResponseReturnsRateLimitedWithNilWhenNoRetryAfterHeader() {
        let response = HTTPURLResponse(
            url: URL(string: "https://example.com")!,
            statusCode: 429,
            httpVersion: nil,
            headerFields: nil
        )!

        XCTAssertEqual(classifyGeminiResponse(response, errorBody: nil), .rateLimited(retryAfter: nil))
    }

    func testClassifyGeminiResponseReturnsNilForSuccess() {
        let response = HTTPURLResponse(
            url: URL(string: "https://example.com")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!

        XCTAssertNil(classifyGeminiResponse(response, errorBody: nil))
    }

    func testClassifyGeminiResponseExtractsErrorMessageFromBody() {
        let response = HTTPURLResponse(
            url: URL(string: "https://example.com")!,
            statusCode: 400,
            httpVersion: nil,
            headerFields: nil
        )!
        let body = Data("""
        {"error": {"message": "Invalid request"}}
        """.utf8)

        XCTAssertEqual(classifyGeminiResponse(response, errorBody: body), .requestFailed("Invalid request"))
    }

    func testClassifyGeminiResponseFallsBackToStatusTextWhenBodyHasNoMessage() {
        let response = HTTPURLResponse(
            url: URL(string: "https://example.com")!,
            statusCode: 500,
            httpVersion: nil,
            headerFields: nil
        )!

        let error = classifyGeminiResponse(response, errorBody: nil)
        guard case .requestFailed(let message) = error else {
            return XCTFail("expected .requestFailed")
        }
        XCTAssertFalse(message.isEmpty)
    }

    // MARK: - Decomposition parsing

    func testParseDecompositionDecodesValidJSON() {
        let json = Data("""
        {"meetingTitleGuess": "Phỏng vấn kỹ thuật", "participantsGuess": ["An", "Đạt"], "topics": [
          {"title": "Giới thiệu", "description": "Giới thiệu team", "richness": 2},
          {"title": "PCB", "description": "Thiết kế mạch", "richness": 5}
        ]}
        """.utf8)

        let decomposition = parseDecomposition(from: json)

        XCTAssertEqual(decomposition?.meetingTitleGuess, "Phỏng vấn kỹ thuật")
        XCTAssertEqual(decomposition?.participantsGuess, ["An", "Đạt"])
        XCTAssertEqual(decomposition?.topics.map(\.title), ["Giới thiệu", "PCB"])
        XCTAssertEqual(decomposition?.topics.map(\.richness), [2, 5])
    }

    func testParseDecompositionReturnsNilOnMalformedJSON() {
        XCTAssertNil(parseDecomposition(from: Data("not json".utf8)))
    }

    func testParseDecompositionReturnsNilWhenNoTopicsSurvive() {
        let json = Data("""
        {"meetingTitleGuess": null, "participantsGuess": [], "topics": [{"title": "", "description": "x", "richness": 3}]}
        """.utf8)

        XCTAssertNil(parseDecomposition(from: json))
    }

    // MARK: - Topic selection

    func testSelectTopicsForExplorationDropsLowRichnessAndCapsByLevel() {
        let topics = [
            NoteTopic(title: "Greeting", description: "", richness: 1),
            NoteTopic(title: "A", description: "", richness: 3),
            NoteTopic(title: "B", description: "", richness: 5),
            NoteTopic(title: "C", description: "", richness: 2),
            NoteTopic(title: "D", description: "", richness: 4),
            NoteTopic(title: "E", description: "", richness: 5)
        ]

        let concise = selectTopicsForExploration(topics, level: .concise)
        XCTAssertEqual(concise.map(\.title), ["A", "B", "D", "E"])
        XCTAssertFalse(concise.contains { $0.title == "Greeting" })

        let detailed = selectTopicsForExploration(topics, level: .detailed)
        XCTAssertEqual(detailed.map(\.title), ["A", "B", "C", "D", "E"])
    }

    func testSelectTopicsForExpansionPicksTopTwoOnlyForDetailed() {
        let topics = [
            NoteTopic(title: "A", description: "", richness: 3),
            NoteTopic(title: "B", description: "", richness: 5),
            NoteTopic(title: "D", description: "", richness: 4)
        ]

        XCTAssertEqual(selectTopicsForExpansion(from: topics, level: .concise), [])
        XCTAssertEqual(selectTopicsForExpansion(from: topics, level: .detailed).map(\.title), ["B", "D"])
    }

    // MARK: - runBounded

    func testRunBoundedNeverExceedsMaxConcurrentAndPreservesOrder() async {
        actor Tracker {
            private(set) var current = 0
            private(set) var maxObserved = 0
            func enter() { current += 1; maxObserved = max(maxObserved, current) }
            func exit() { current -= 1 }
        }
        let tracker = Tracker()
        let items = Array(0..<9)

        let results = await runBounded(items, maxConcurrent: 3) { item -> Int in
            await tracker.enter()
            try? await Task.sleep(nanoseconds: 5_000_000)
            await tracker.exit()
            return item * 2
        }

        let maxObserved = await tracker.maxObserved
        XCTAssertLessThanOrEqual(maxObserved, 3)
        XCTAssertEqual(results, items.map { $0 * 2 })
    }

    func testRunBoundedHandlesEmptyInput() async {
        let results: [Int] = await runBounded([Int](), maxConcurrent: 3) { $0 }
        XCTAssertTrue(results.isEmpty)
    }

    // MARK: - withRetry

    func testWithRetryRetriesTransientFailuresAndEventuallySucceeds() async throws {
        actor CallCount {
            private(set) var count = 0
            func increment() -> Int { count += 1; return count }
        }
        let calls = CallCount()
        let policy = RetryPolicy(maxAttempts: 4, baseDelay: 0.01, maxDelay: 0.02)

        let result = try await withRetry(policy: policy) {
            let attempt = await calls.increment()
            if attempt < 3 { throw GeminiTranscriptionError.requestFailed("transient") }
            return "ok"
        }

        XCTAssertEqual(result, "ok")
        let finalCount = await calls.count
        XCTAssertEqual(finalCount, 3)
    }

    func testWithRetryGivesUpAfterMaxAttempts() async {
        let policy = RetryPolicy(maxAttempts: 3, baseDelay: 0.01, maxDelay: 0.02)

        do {
            _ = try await withRetry(policy: policy) {
                throw GeminiTranscriptionError.requestFailed("always fails")
            } as String
            XCTFail("expected withRetry to throw")
        } catch {
            XCTAssertEqual(error as? GeminiTranscriptionError, .requestFailed("always fails"))
        }
    }

    func testWithRetryDoesNotRetryNonTransientErrors() async {
        actor CallCount {
            private(set) var count = 0
            func increment() { count += 1 }
        }
        let calls = CallCount()
        let policy = RetryPolicy(maxAttempts: 4, baseDelay: 0.01, maxDelay: 0.02)

        do {
            _ = try await withRetry(policy: policy) {
                await calls.increment()
                throw GeminiTranscriptionError.invalidResponse("bad") as Error
            } as String
            XCTFail("expected error")
        } catch {}

        let finalCount = await calls.count
        XCTAssertEqual(finalCount, 1)
    }

    func testWithRetryHonorsRateLimitedRetryAfter() async throws {
        actor CallCount {
            private(set) var count = 0
            func increment() -> Int { count += 1; return count }
        }
        let calls = CallCount()
        let policy = RetryPolicy(maxAttempts: 3, baseDelay: 0.01, maxDelay: 0.02)
        let start = Date()

        let result = try await withRetry(policy: policy) {
            let attempt = await calls.increment()
            if attempt < 2 { throw GeminiTranscriptionError.rateLimited(retryAfter: 0.02) }
            return "ok"
        }

        XCTAssertEqual(result, "ok")
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.02)
    }

    // MARK: - Prompts

    func testDecomposePromptIncludesTheTranscript() {
        let prompt = decomposePrompt(transcript: "unique-transcript-marker-123")
        XCTAssertTrue(prompt.contains("unique-transcript-marker-123"))
    }

    func testExplorePromptFocusesOnTheGivenTopicAndIncludesAddendum() {
        let topic = NoteTopic(title: "PCB design", description: "Mạch điện", richness: 5)
        let prompt = explorePrompt(topic: topic, transcript: "unique-transcript-marker-456", detailAddendum: "- extra rule here")

        XCTAssertTrue(prompt.contains("PCB design"))
        XCTAssertTrue(prompt.contains("unique-transcript-marker-456"))
        XCTAssertTrue(prompt.contains("extra rule here"))
    }

    func testExpandPromptIncludesPriorFindingsAndTranscript() {
        let topic = NoteTopic(title: "PCB design", description: "Mạch điện", richness: 5)
        let prompt = expandPrompt(
            topic: topic,
            priorFindings: "unique-prior-findings-789",
            transcript: "unique-transcript-marker-999",
            detailAddendum: ""
        )

        XCTAssertTrue(prompt.contains("unique-prior-findings-789"))
        XCTAssertTrue(prompt.contains("unique-transcript-marker-999"))
    }

    func testSynthesizePromptIncludesHeaderMetadataAndTopicFindings() {
        let prompt = synthesizePrompt(
            today: "30/08/2026",
            meetingTitleGuess: "Phỏng vấn kỹ thuật",
            participantsGuess: ["An", "Đạt"],
            topicFindings: [(title: "PCB design", content: "unique-finding-content-321")],
            detailAddendum: ""
        )

        XCTAssertTrue(prompt.contains("Phỏng vấn kỹ thuật"))
        XCTAssertTrue(prompt.contains("An, Đạt"))
        XCTAssertTrue(prompt.contains("30/08/2026"))
        XCTAssertTrue(prompt.contains("PCB design"))
        XCTAssertTrue(prompt.contains("unique-finding-content-321"))
    }

    func testSynthesizePromptHandlesMissingTitleAndParticipants() {
        let prompt = synthesizePrompt(
            today: "30/08/2026",
            meetingTitleGuess: nil,
            participantsGuess: [],
            topicFindings: [(title: "A", content: "x")],
            detailAddendum: ""
        )

        XCTAssertFalse(prompt.isEmpty)
    }
}
