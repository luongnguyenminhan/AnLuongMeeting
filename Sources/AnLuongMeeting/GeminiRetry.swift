import Foundation

/// Retries a Gemini API call with exponential backoff, but only for transient failures — a
/// rate limit (honoring `Retry-After` if the server sent one) or a network/transport error.
/// Any other error (invalid API key, malformed request, a generic 4xx/5xx `.requestFailed`)
/// fails immediately: `.requestFailed` doesn't currently carry the HTTP status code, so there's
/// no reliable way to tell a retryable 503 from a non-retryable 400 without guessing at the
/// error string, and guessing at error strings is worse than not retrying those cases at all.
enum GeminiRetry {
    static let maxAttempts = 3

    static func run<T>(
        sleep: @escaping @Sendable (TimeInterval) async -> Void = { seconds in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        },
        operation: @Sendable () async throws -> T
    ) async throws -> T {
        var attempt = 1
        while true {
            do {
                return try await operation()
            } catch {
                guard attempt < maxAttempts, let delay = retryDelay(for: error, attempt: attempt) else {
                    throw error
                }
                await sleep(delay)
                attempt += 1
            }
        }
    }

    /// Returns the delay before the next attempt, or `nil` if `error` shouldn't be retried.
    static func retryDelay(for error: Error, attempt: Int) -> TimeInterval? {
        let backoff = pow(2.0, Double(attempt - 1))
        if case GeminiTranscriptionError.rateLimited(let retryAfter) = error {
            return retryAfter ?? backoff
        }
        if error is URLError {
            return backoff
        }
        return nil
    }
}
