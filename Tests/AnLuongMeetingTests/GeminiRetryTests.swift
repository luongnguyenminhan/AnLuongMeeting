import XCTest
@testable import AnLuongMeeting

final class GeminiRetryTests: XCTestCase {
    func testSucceedsWithoutRetryingOnFirstSuccess() async throws {
        var calls = 0
        let result = try await GeminiRetry.run(sleep: { _ in }) {
            calls += 1
            return "ok"
        }
        XCTAssertEqual(result, "ok")
        XCTAssertEqual(calls, 1)
    }

    func testRetriesOnRateLimitedUpToMaxAttempts() async {
        var calls = 0
        do {
            _ = try await GeminiRetry.run(sleep: { _ in }) {
                calls += 1
                throw GeminiTranscriptionError.rateLimited(retryAfter: nil)
            } as String
            XCTFail("expected to throw after exhausting retries")
        } catch {
            XCTAssertEqual(calls, GeminiRetry.maxAttempts)
        }
    }

    func testSucceedsAfterATransientFailure() async throws {
        var calls = 0
        let result = try await GeminiRetry.run(sleep: { _ in }) {
            calls += 1
            if calls < 2 { throw URLError(.networkConnectionLost) }
            return "recovered"
        }
        XCTAssertEqual(result, "recovered")
        XCTAssertEqual(calls, 2)
    }

    func testDoesNotRetryNonTransientErrors() async {
        var calls = 0
        do {
            _ = try await GeminiRetry.run(sleep: { _ in }) {
                calls += 1
                throw GeminiTranscriptionError.requestFailed("bad request")
            } as String
            XCTFail("expected to throw immediately")
        } catch {
            XCTAssertEqual(calls, 1)
        }
    }

    func testRetryDelayHonorsServerSuppliedRetryAfter() {
        let delay = GeminiRetry.retryDelay(for: GeminiTranscriptionError.rateLimited(retryAfter: 7), attempt: 1)
        XCTAssertEqual(delay, 7)
    }

    func testRetryDelayBacksOffExponentiallyWithoutServerHint() {
        XCTAssertEqual(GeminiRetry.retryDelay(for: URLError(.timedOut), attempt: 1), 1)
        XCTAssertEqual(GeminiRetry.retryDelay(for: URLError(.timedOut), attempt: 2), 2)
        XCTAssertEqual(GeminiRetry.retryDelay(for: URLError(.timedOut), attempt: 3), 4)
    }
}
