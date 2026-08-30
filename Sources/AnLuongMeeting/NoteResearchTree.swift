import Foundation

/// Classifies an HTTP response from the Gemini API into a `GeminiTranscriptionError`,
/// or `nil` if the response is a success (2xx). Kept separate from `GeminiTranscriptionService`
/// so it's directly unit-testable without a network round trip.
func classifyGeminiResponse(_ response: HTTPURLResponse, errorBody: Data?) -> GeminiTranscriptionError? {
    if response.statusCode == 429 {
        let retryAfter = response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
        return .rateLimited(retryAfter: retryAfter)
    }
    guard (200..<300).contains(response.statusCode) else {
        let message = errorBody.flatMap(extractGeminiErrorMessage)
            ?? HTTPURLResponse.localizedString(forStatusCode: response.statusCode)
        return .requestFailed(message)
    }
    return nil
}

func extractGeminiErrorMessage(from data: Data) -> String? {
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let error = root["error"] as? [String: Any] else {
        return nil
    }
    return error["message"] as? String
}

struct NoteTopic: Sendable, Equatable {
    let title: String
    let description: String
    let richness: Int
}

struct NoteDecomposition: Sendable, Equatable {
    let meetingTitleGuess: String?
    let participantsGuess: [String]
    let topics: [NoteTopic]
}

func decomposeSchema() -> [String: Any] {
    [
        "type": "OBJECT",
        "properties": [
            "meetingTitleGuess": ["type": "STRING"],
            "participantsGuess": ["type": "ARRAY", "items": ["type": "STRING"]],
            "topics": [
                "type": "ARRAY",
                "items": [
                    "type": "OBJECT",
                    "properties": [
                        "title": ["type": "STRING"],
                        "description": ["type": "STRING"],
                        "richness": ["type": "NUMBER"]
                    ],
                    "required": ["title", "description", "richness"]
                ]
            ]
        ],
        "required": ["meetingTitleGuess", "participantsGuess", "topics"]
    ]
}

func parseDecomposition(from json: Data) -> NoteDecomposition? {
    struct RawTopic: Decodable {
        let title: String?
        let description: String?
        let richness: Double?
    }
    struct RawDecomposition: Decodable {
        let meetingTitleGuess: String?
        let participantsGuess: [String]?
        let topics: [RawTopic]?
    }
    guard let raw = try? JSONDecoder().decode(RawDecomposition.self, from: json) else { return nil }

    let topics: [NoteTopic] = (raw.topics ?? []).compactMap { entry in
        guard let title = entry.title, !title.isEmpty else { return nil }
        return NoteTopic(
            title: title,
            description: entry.description ?? "",
            richness: Int((entry.richness ?? 0).rounded())
        )
    }
    guard !topics.isEmpty else { return nil }

    return NoteDecomposition(
        meetingTitleGuess: raw.meetingTitleGuess,
        participantsGuess: raw.participantsGuess ?? [],
        topics: topics
    )
}

/// Drops topics with `richness <= 1` (small talk, logistics), then caps the survivors —
/// 4 for `.concise`, 8 for `.detailed` — keeping the highest-richness ones, and finally
/// re-sorts the kept topics back into their original order so the note reads naturally.
func selectTopicsForExploration(_ topics: [NoteTopic], level: NoteDetailLevel) -> [NoteTopic] {
    let maxTopics = level == .detailed ? 8 : 4
    let indexed = Array(topics.enumerated())
    let survivors = indexed.filter { $0.element.richness > 1 }
    let kept = survivors
        .sorted { $0.element.richness > $1.element.richness }
        .prefix(maxTopics)
    return kept
        .sorted { $0.offset < $1.offset }
        .map(\.element)
}

/// Picks the top 2 richest topics (from the already-pruned survivors) for a deeper
/// follow-up pass. Concise never expands.
func selectTopicsForExpansion(from survivingTopics: [NoteTopic], level: NoteDetailLevel) -> [NoteTopic] {
    guard level == .detailed else { return [] }
    return Array(survivingTopics.sorted { $0.richness > $1.richness }.prefix(2))
}

/// Runs `work` over `items`, keeping at most `maxConcurrent` invocations in flight at once
/// (refilling as each finishes) instead of firing everything simultaneously. Results are
/// returned in the same order as `items`.
func runBounded<Item: Sendable, Result: Sendable>(
    _ items: [Item],
    maxConcurrent: Int,
    work: @escaping @Sendable (Item) async -> Result
) async -> [Result] {
    guard !items.isEmpty else { return [] }
    var results = [Result?](repeating: nil, count: items.count)
    var nextIndex = 0

    await withTaskGroup(of: (Int, Result).self) { group in
        func addNext() {
            guard nextIndex < items.count else { return }
            let index = nextIndex
            let item = items[index]
            nextIndex += 1
            group.addTask { (index, await work(item)) }
        }

        let initial = min(maxConcurrent, items.count)
        for _ in 0..<initial { addNext() }

        while let (index, result) = await group.next() {
            results[index] = result
            addNext()
        }
    }

    return results.map { $0! }
}

/// A thread-safe counter for reporting incremental progress from within `runBounded`'s
/// concurrently-executing work closures (a plain captured `var` would be a data race).
actor ProgressCounter {
    private(set) var count = 0

    func increment() -> Int {
        count += 1
        return count
    }
}

struct RetryPolicy: Sendable {
    let maxAttempts: Int
    let baseDelay: TimeInterval
    let maxDelay: TimeInterval

    static let geminiDefault = RetryPolicy(maxAttempts: 4, baseDelay: 2, maxDelay: 16)
}

/// Returns a non-negative "explicit" delay hint for a retryable error (0 means "retryable,
/// use the policy's default backoff"), or `nil` if the error should not be retried at all.
func isRetryableGeminiError(_ error: Error) -> TimeInterval? {
    switch error {
    case GeminiTranscriptionError.rateLimited(let retryAfter):
        return retryAfter ?? 0
    case GeminiTranscriptionError.requestFailed:
        return 0
    default:
        return nil
    }
}

/// Retries `operation` up to `policy.maxAttempts` times. On a retryable failure, waits for
/// the error's explicit delay (e.g. a `Retry-After` value) when one is given, otherwise an
/// exponential backoff from `policy.baseDelay`, capped at `policy.maxDelay`, plus jitter.
func withRetry<T: Sendable>(
    policy: RetryPolicy = .geminiDefault,
    isRetryable: (Error) -> TimeInterval? = isRetryableGeminiError,
    operation: @Sendable () async throws -> T
) async throws -> T {
    var attempt = 1
    while true {
        do {
            return try await operation()
        } catch {
            guard attempt < policy.maxAttempts, let explicitDelay = isRetryable(error) else {
                throw error
            }
            let backoff = policy.baseDelay * pow(2.0, Double(attempt - 1))
            let baseDelay = explicitDelay > 0 ? min(explicitDelay, policy.maxDelay) : min(backoff, policy.maxDelay)
            let jittered = baseDelay * (1 + Double.random(in: 0...0.2))
            try await Task.sleep(nanoseconds: UInt64(max(jittered, 0) * 1_000_000_000))
            attempt += 1
        }
    }
}

func decomposePrompt(transcript: String) -> String {
    """
    Bạn đang phân tích bản chép lời một cuộc họp để chuẩn bị viết ghi chú chi tiết theo từng chủ đề.

    Đọc kỹ bản chép lời bên dưới và xác định:
    1. Tên cuộc họp có thể suy ra được (meetingTitleGuess) — để trống nếu không rõ.
    2. Danh sách người tham gia có thể xác định được qua tên được nhắc đến (participantsGuess).
    3. Các chủ đề chính đã được thảo luận (topics), mỗi chủ đề gồm:
       - title: tên ngắn gọn của chủ đề
       - description: mô tả 1 câu về nội dung chủ đề đó
       - richness: điểm từ 1 đến 5 đánh giá mức độ nội dung thực chất của chủ đề (kỹ thuật, quyết định, số liệu, tranh luận sâu) — 1 là chào hỏi/kiểm tra âm thanh/nói chuyện phiếm không có nội dung, 5 là thảo luận sâu, nhiều chi tiết kỹ thuật hoặc quyết định quan trọng.

    Liệt kê các chủ đề theo đúng thứ tự chúng xuất hiện trong bản chép lời. Không bỏ sót chủ đề nào có nội dung thực chất, kể cả chủ đề ngắn.

    BẢN CHÉP LỜI:
    \(transcript)
    """
}

func explorePrompt(topic: NoteTopic, transcript: String, detailAddendum: String) -> String {
    """
    Bạn đang đào sâu vào MỘT chủ đề cụ thể trong bản chép lời cuộc họp bên dưới, để chuẩn bị dữ liệu cho một ghi chú cuộc họp chi tiết.

    CHỦ ĐỀ CẦN TẬP TRUNG: \(topic.title)
    Mô tả ngắn: \(topic.description)

    Chỉ tập trung vào nội dung liên quan đến chủ đề này, bỏ qua các chủ đề khác. Viết bằng tiếng Việt, trình bày thành các gạch đầu dòng chi tiết, bao gồm:
    - Các điểm chính và điểm phụ đã được thảo luận về chủ đề này.
    - Số liệu, thông số kỹ thuật, tên công cụ/thiết bị/giao thức được nhắc đến, giữ nguyên chính xác.
    - Trích dẫn nguyên văn các câu nói quan trọng khi phù hợp, ghi rõ người nói nếu xác định được.
    - Quyết định hoặc việc cần làm liên quan đến chủ đề này, nếu có.
    - Các điểm chưa thống nhất hoặc câu hỏi còn bỏ ngỏ liên quan đến chủ đề này.

    KHÔNG suy diễn hay thêm thông tin không có trong bản chép lời. Nếu bản chép lời không đủ chi tiết cho một mục nào đó, bỏ qua mục đó thay vì đoán.\(detailAddendum)

    BẢN CHÉP LỜI ĐẦY ĐỦ:
    \(transcript)
    """
}

func expandPrompt(topic: NoteTopic, priorFindings: String, transcript: String, detailAddendum: String) -> String {
    """
    Bạn đã viết một bản tìm hiểu ban đầu về chủ đề "\(topic.title)" từ bản chép lời cuộc họp. Chủ đề này được đánh giá là có nhiều nội dung thực chất, vì vậy hãy viết lại bản tìm hiểu này ở mức chi tiết SÂU HƠN.

    BẢN TÌM HIỂU BAN ĐẦU (dùng làm điểm khởi đầu, không phải bản cuối):
    \(priorFindings)

    Đọc lại bản chép lời đầy đủ bên dưới và viết một bản tìm hiểu MỚI, đầy đủ hơn về chủ đề này — giữ lại mọi điểm đã có ở bản ban đầu, đồng thời bổ sung thêm các điểm phụ, số liệu, trích dẫn, hoặc sắc thái mà bản ban đầu chưa nêu ra. Viết bằng tiếng Việt, gạch đầu dòng. Đây sẽ là bản DUY NHẤT được dùng cho chủ đề này trong ghi chú cuối cùng.\(detailAddendum)

    BẢN CHÉP LỜI ĐẦY ĐỦ:
    \(transcript)
    """
}

private func topicFindingsBlock(_ findings: [(title: String, content: String)]) -> String {
    findings.enumerated().map { index, item in
        "### \(index + 1). \(item.title)\n\(item.content)"
    }.joined(separator: "\n\n")
}

func synthesizePrompt(
    today: String,
    meetingTitleGuess: String?,
    participantsGuess: [String],
    topicFindings: [(title: String, content: String)],
    detailAddendum: String
) -> String {
    let titleLine = (meetingTitleGuess?.isEmpty == false) ? meetingTitleGuess! : "(không rõ, hãy tự đặt tên phù hợp)"
    let participantsLine = participantsGuess.isEmpty ? "(không xác định được)" : participantsGuess.joined(separator: ", ")

    return """
    Bạn đang tổng hợp ghi chú cuộc họp cuối cùng bằng tiếng Việt, dựa trên các bản tìm hiểu chi tiết theo từng chủ đề bên dưới (đã được trích xuất sẵn từ bản chép lời gốc).

    Tên cuộc họp gợi ý: \(titleLine)
    Người tham gia gợi ý: \(participantsLine)
    Người dùng xác nhận ngày họp là hôm nay: \(today).

    Hãy tổ chức lại nội dung từ các bản tìm hiểu theo từng chủ đề bên dưới thành MỘT ghi chú cuộc họp mạch lạc, đầy đủ. KHÔNG bỏ sót thông tin đã có trong các bản tìm hiểu — nhiệm vụ của bạn là tổ chức và trình bày lại, không phải tóm tắt thêm. Rút ra các quyết định và việc cần làm được đề cập trong bất kỳ bản tìm hiểu nào vào đúng mục tương ứng. Không coi nhãn SPEAKER_<number> là tên thật của một người.\(detailAddendum)

    ĐỊNH DẠNG BẮT BUỘC:
    # [TÊN CUỘC HỌP]
    ## Thông tin chung
    - **Ngày họp**: \(today)
    - **Chủ đề**: [chủ đề chính của cuộc họp]
    - **Người tham gia**: [danh sách người tham gia nếu có thể xác định]

    ## Tóm tắt nội dung
    [Tóm tắt ngắn gọn 3-5 câu về nội dung chính của cuộc họp]

    ## Các chủ đề được thảo luận
    [Trình bày lại từng chủ đề bên dưới thành các mục có đánh số, giữ nguyên chi tiết, trích dẫn và số liệu đã có]

    ## Quyết định quan trọng
    - [Quyết định 1]
    - [Quyết định 2]

    ## Công việc cần thực hiện
    - [Công việc 1] - Người phụ trách: [Tên], Deadline: [Thời hạn nếu có]
    - [Công việc 2] - Người phụ trách: [Tên], Deadline: [Thời hạn nếu có]

    Chỉ trả về nội dung ghi chú theo đúng định dạng trên. Không thêm lời giải thích trước hoặc sau ghi chú.

    CÁC BẢN TÌM HIỂU THEO CHỦ ĐỀ:
    \(topicFindingsBlock(topicFindings))
    """
}

extension GeminiTranscriptionService {
    /// Generates a meeting note via the decompose → explore → expand → synthesize pipeline.
    /// Falls back to the original single-call whole-transcript prompt if decomposition fails
    /// or no topic survives pruning. A topic whose explore/expand call fails after retries is
    /// dropped from the note rather than failing the whole generation.
    func generateMeetingNoteViaResearchTree(
        transcript: String,
        apiKey: String,
        memoryContext: String?,
        meetingDate: String,
        progress: @escaping @Sendable (TranscriptionProgress) -> Void
    ) async throws -> String {
        let preferences = NoteDetailPreferences.loadSaved()
        let detailAddendum = preferences.promptAddendum

        func fallbackToSingleCall() async throws -> String {
            try await generateText(
                parts: [["text": Self.meetingNotePrompt(today: meetingDate, detailAddendum: detailAddendum) + "\n" + transcript]],
                systemInstruction: memoryContext,
                apiKey: apiKey
            )
        }

        guard
            let decomposeJSON = try? await withRetry(operation: {
                try await self.generateStructuredJSON(
                    prompt: decomposePrompt(transcript: transcript),
                    schema: decomposeSchema(),
                    apiKey: apiKey
                )
            }),
            let decomposition = parseDecomposition(from: decomposeJSON)
        else {
            return try await fallbackToSingleCall()
        }

        let survivingTopics = selectTopicsForExploration(decomposition.topics, level: preferences.level)
        guard !survivingTopics.isEmpty else {
            return try await fallbackToSingleCall()
        }

        progress(TranscriptionProgress(
            stage: .meetingNote,
            currentSegment: 0,
            totalSegments: survivingTopics.count
        ))

        let exploreCounter = ProgressCounter()
        let exploreResults: [String?] = await runBounded(survivingTopics, maxConcurrent: 3) { topic in
            let text: String?
            do {
                text = try await withRetry {
                    try await self.generateText(
                        parts: [["text": explorePrompt(topic: topic, transcript: transcript, detailAddendum: detailAddendum)]],
                        systemInstruction: memoryContext,
                        apiKey: apiKey
                    )
                }
            } catch {
                text = nil
            }
            let completed = await exploreCounter.increment()
            progress(TranscriptionProgress(
                stage: .meetingNote,
                currentSegment: completed,
                totalSegments: survivingTopics.count
            ))
            return text
        }

        var findings: [(title: String, content: String)] = zip(survivingTopics, exploreResults).compactMap { topic, text in
            guard let text else { return nil }
            return (topic.title, text)
        }
        guard !findings.isEmpty else {
            return try await fallbackToSingleCall()
        }

        let expansionCandidates = selectTopicsForExpansion(from: survivingTopics, level: preferences.level)
        if !expansionCandidates.isEmpty {
            progress(TranscriptionProgress(
                stage: .meetingNote,
                currentSegment: survivingTopics.count,
                totalSegments: survivingTopics.count
            ))
            let expandResults: [(String, String)?] = await runBounded(expansionCandidates, maxConcurrent: 3) { topic in
                guard let prior = findings.first(where: { $0.title == topic.title })?.content else { return nil }
                do {
                    let deeper = try await withRetry {
                        try await self.generateText(
                            parts: [["text": expandPrompt(topic: topic, priorFindings: prior, transcript: transcript, detailAddendum: detailAddendum)]],
                            systemInstruction: memoryContext,
                            apiKey: apiKey
                        )
                    }
                    return (topic.title, deeper)
                } catch {
                    return nil
                }
            }
            for case let (title, deeper)? in expandResults {
                if let idx = findings.firstIndex(where: { $0.title == title }) {
                    findings[idx].content = deeper
                }
            }
        }

        progress(TranscriptionProgress(
            stage: .meetingNote,
            currentSegment: survivingTopics.count,
            totalSegments: survivingTopics.count
        ))

        return try await withRetry {
            try await self.generateText(
                parts: [["text": synthesizePrompt(
                    today: meetingDate,
                    meetingTitleGuess: decomposition.meetingTitleGuess,
                    participantsGuess: decomposition.participantsGuess,
                    topicFindings: findings,
                    detailAddendum: detailAddendum
                )]],
                systemInstruction: memoryContext,
                apiKey: apiKey
            )
        }
    }
}
