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

/// Appended to every note-generation prompt. The system instruction (built from confirmed
/// memory) lists known terms/names together with ASR mishearings of them (e.g. "Celesnity
/// (also heard as: Celesta)") — but without this explicit call-out, the model tends to
/// reproduce the transcript's literal (mis-transcribed) spelling instead, since it reads
/// "don't add info not in the transcript" as "don't touch the wording."  Applying a known
/// spelling correction is not adding information, so say so directly.
let spellingCorrectionInstruction = """


QUAN TRỌNG — sửa lỗi chính tả đã biết: nếu phần hướng dẫn hệ thống liệt kê một thuật ngữ/tên riêng đã xác nhận kèm các biến thể "cũng nghe thành: ..." (ASR nghe nhầm), và bản chép lời bên dưới chứa biến thể đó, hãy viết theo đúng chính tả đã xác nhận thay vì chép lại biến thể nghe nhầm. Đây là sửa lỗi phiên âm đã biết, KHÔNG phải suy diễn hay thêm thông tin mới.
"""

func decomposePrompt(transcript: String, detailAddendum: String = "") -> String {
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

    QUAN TRỌNG — tránh chủ đề trùng lặp: nếu cuộc họp quay lại thảo luận cùng một nội dung cốt lõi nhiều lần dưới các góc độ khác nhau (ví dụ: một buổi phỏng vấn nhắc đi nhắc lại cùng một kỹ năng hoặc yêu cầu), hãy gộp các đoạn đó thành MỘT chủ đề duy nhất thay vì tách thành nhiều chủ đề riêng biệt — mỗi chủ đề phải đại diện cho một nội dung thực sự khác biệt, không chồng lấn với chủ đề khác.\(spellingCorrectionInstruction)\(detailAddendum)

    BẢN CHÉP LỜI:
    \(transcript)
    """
}

func explorePrompt(topic: NoteTopic, transcript: String, detailAddendum: String) -> String {
    """
    Bạn đang đào sâu vào MỘT chủ đề cụ thể trong bản chép lời cuộc họp bên dưới, để chuẩn bị dữ liệu cho một ghi chú cuộc họp chi tiết.

    CHỦ ĐỀ CẦN TẬP TRUNG: \(topic.title)
    Mô tả ngắn: \(topic.description)

    Chỉ tập trung vào nội dung liên quan đến chủ đề này, bỏ qua các chủ đề khác. Mặc định viết bằng tiếng Việt (trừ khi yêu cầu bổ sung bên dưới chỉ định ngôn ngữ khác), trình bày thành các gạch đầu dòng chi tiết, bao gồm:
    - Các điểm chính và điểm phụ đã được thảo luận về chủ đề này.
    - Số liệu, thông số kỹ thuật, tên công cụ/thiết bị/giao thức được nhắc đến, giữ nguyên chính xác.
    - Trích dẫn nguyên văn các câu nói quan trọng khi phù hợp, ghi rõ người nói nếu xác định được.
    - Các điểm chưa thống nhất hoặc câu hỏi còn bỏ ngỏ liên quan đến chủ đề này.

    KHÔNG liệt kê quyết định hay việc cần làm ở đây — một bước riêng ở cuối sẽ tổng hợp quyết định và việc cần làm từ TOÀN BỘ các chủ đề, nên lặp lại chúng ở đây sẽ tạo nội dung trùng lặp trong ghi chú cuối cùng.

    KHÔNG suy diễn hay thêm thông tin không có trong bản chép lời. Nếu bản chép lời không đủ chi tiết cho một mục nào đó, bỏ qua mục đó thay vì đoán. KHÔNG được thêm BẤT KỲ tiêu đề Markdown nào (#, ##, ###) ở bất kỳ đâu trong câu trả lời — kể cả tiêu đề tự đặt như "Overview", "Tóm tắt", "Quyết định" — dù bộ nhớ phong cách ghi chú bên dưới có gợi ý dùng tiêu đề cho CẢ ghi chú, điều đó KHÔNG áp dụng ở bước này. Chỉ trả về MỘT danh sách gạch đầu dòng phẳng, không heading, không mục con có tiêu đề riêng, vì tiêu đề chủ đề đã được thêm riêng vào ghi chú cuối cùng.\(spellingCorrectionInstruction)\(detailAddendum)

    BẢN CHÉP LỜI ĐẦY ĐỦ:
    \(transcript)
    """
}

func expandPrompt(topic: NoteTopic, priorFindings: String, transcript: String, detailAddendum: String) -> String {
    """
    Bạn đã viết một bản tìm hiểu ban đầu về chủ đề "\(topic.title)" từ bản chép lời cuộc họp. Chủ đề này được đánh giá là có nhiều nội dung thực chất, vì vậy hãy viết lại bản tìm hiểu này ở mức chi tiết SÂU HƠN.

    BẢN TÌM HIỂU BAN ĐẦU (dùng làm điểm khởi đầu, không phải bản cuối):
    \(priorFindings)

    Đọc lại bản chép lời đầy đủ bên dưới và viết một bản tìm hiểu MỚI, đầy đủ hơn về chủ đề này — giữ lại mọi điểm đã có ở bản ban đầu, đồng thời bổ sung thêm các điểm phụ, số liệu, trích dẫn, hoặc sắc thái mà bản ban đầu chưa nêu ra. Mặc định viết bằng tiếng Việt (trừ khi yêu cầu bổ sung bên dưới chỉ định ngôn ngữ khác), gạch đầu dòng.

    KHÔNG liệt kê quyết định hay việc cần làm ở đây — một bước riêng ở cuối sẽ tổng hợp quyết định và việc cần làm từ TOÀN BỘ các chủ đề, nên lặp lại chúng ở đây sẽ tạo nội dung trùng lặp trong ghi chú cuối cùng.

    KHÔNG được thêm BẤT KỲ tiêu đề Markdown nào (#, ##, ###) ở bất kỳ đâu trong câu trả lời — kể cả tiêu đề tự đặt như "Overview", "Tóm tắt", "Quyết định" — dù bộ nhớ phong cách ghi chú bên dưới có gợi ý dùng tiêu đề cho CẢ ghi chú, điều đó KHÔNG áp dụng ở bước này. Chỉ trả về MỘT danh sách gạch đầu dòng phẳng, không heading, không mục con có tiêu đề riêng. Đây sẽ là bản DUY NHẤT được dùng cho chủ đề này trong ghi chú cuối cùng.\(spellingCorrectionInstruction)\(detailAddendum)

    BẢN CHÉP LỜI ĐẦY ĐỦ:
    \(transcript)
    """
}

private func topicFindingsBlock(_ findings: [(title: String, content: String)]) -> String {
    findings.enumerated().map { index, item in
        "### \(index + 1). \(item.title)\n\(item.content)"
    }.joined(separator: "\n\n")
}

struct SynthesisActionItem: Sendable, Equatable {
    let task: String
    let owner: String?
    let deadline: String?
}

/// Section-header words for the assembled note. Returned by the model (in whatever language
/// was requested) rather than hardcoded, so a language override in the user's extra
/// instructions applies to structural headers too, not just free-text content.
struct SynthesisLabels: Sendable, Equatable {
    let generalInfoHeading: String
    let dateLabel: String
    let topicLabel: String
    let participantsLabel: String
    let summaryHeading: String
    let topicsHeading: String
    let decisionsHeading: String
    let actionItemsHeading: String
    let ownerLabel: String
    let deadlineLabel: String

    static let defaultVietnamese = SynthesisLabels(
        generalInfoHeading: "Thông tin chung",
        dateLabel: "Ngày họp",
        topicLabel: "Chủ đề",
        participantsLabel: "Người tham gia",
        summaryHeading: "Tóm tắt nội dung",
        topicsHeading: "Các chủ đề được thảo luận",
        decisionsHeading: "Quyết định quan trọng",
        actionItemsHeading: "Công việc cần thực hiện",
        ownerLabel: "Người phụ trách",
        deadlineLabel: "Deadline"
    )
}

struct SynthesisMetadata: Sendable, Equatable {
    let meetingTitle: String
    let topicSentence: String
    let participants: [String]
    let summary: String
    let decisions: [String]
    let actionItems: [SynthesisActionItem]
    let labels: SynthesisLabels
}

func synthesizeMetadataSchema() -> [String: Any] {
    let actionItemSchema: [String: Any] = [
        "type": "OBJECT",
        "properties": [
            "task": ["type": "STRING"],
            "owner": ["type": "STRING"],
            "deadline": ["type": "STRING"]
        ],
        "required": ["task"]
    ]
    let labelsSchema: [String: Any] = [
        "type": "OBJECT",
        "properties": [
            "generalInfoHeading": ["type": "STRING"],
            "dateLabel": ["type": "STRING"],
            "topicLabel": ["type": "STRING"],
            "participantsLabel": ["type": "STRING"],
            "summaryHeading": ["type": "STRING"],
            "topicsHeading": ["type": "STRING"],
            "decisionsHeading": ["type": "STRING"],
            "actionItemsHeading": ["type": "STRING"],
            "ownerLabel": ["type": "STRING"],
            "deadlineLabel": ["type": "STRING"]
        ],
        "required": [
            "generalInfoHeading", "dateLabel", "topicLabel", "participantsLabel",
            "summaryHeading", "topicsHeading", "decisionsHeading", "actionItemsHeading",
            "ownerLabel", "deadlineLabel"
        ]
    ]
    return [
        "type": "OBJECT",
        "properties": [
            "meetingTitle": ["type": "STRING"],
            "topicSentence": ["type": "STRING"],
            "participants": ["type": "ARRAY", "items": ["type": "STRING"]],
            "summary": ["type": "STRING"],
            "decisions": ["type": "ARRAY", "items": ["type": "STRING"]],
            "actionItems": ["type": "ARRAY", "items": actionItemSchema],
            "labels": labelsSchema
        ],
        "required": ["meetingTitle", "topicSentence", "participants", "summary", "decisions", "actionItems", "labels"]
    ]
}

/// Asks only for the header/summary/decisions/action-items metadata — never for a
/// reproduction of the topic write-ups themselves, which are pasted in verbatim by
/// `assembleFinalNote` instead of being re-generated (an LLM asked to losslessly copy
/// tens of thousands of characters reliably summarizes instead, however strongly worded
/// the instruction not to).
func synthesizeMetadataPrompt(
    today: String,
    meetingTitleGuess: String?,
    participantsGuess: [String],
    topicFindings: [(title: String, content: String)],
    detailAddendum: String
) -> String {
    let titleLine = (meetingTitleGuess?.isEmpty == false) ? meetingTitleGuess! : "(không rõ, hãy tự đặt tên phù hợp)"
    let participantsLine = participantsGuess.isEmpty ? "(không xác định được)" : participantsGuess.joined(separator: ", ")

    return """
    Bạn đang chuẩn bị phần mở đầu và kết luận cho một ghi chú cuộc họp, dựa trên các bản tìm hiểu chi tiết theo từng chủ đề bên dưới. Các bản tìm hiểu này sẽ được đưa NGUYÊN VĂN vào ghi chú cuối cùng — bạn KHÔNG cần và KHÔNG được viết lại hay tóm tắt chúng.

    Tên cuộc họp gợi ý: \(titleLine)
    Người tham gia gợi ý: \(participantsLine)
    Người dùng xác nhận ngày họp là hôm nay: \(today).

    Dựa trên nội dung các bản tìm hiểu, hãy cung cấp:
    - meetingTitle: tên cuộc họp phù hợp.
    - topicSentence: một câu mô tả chủ đề chính của cuộc họp.
    - participants: danh sách người tham gia (dùng danh sách gợi ý nếu hợp lý, bổ sung nếu bản tìm hiểu nêu rõ thêm).
    - summary: đoạn tóm tắt 3-5 câu về nội dung chính của cuộc họp.
    - decisions: danh sách các quyết định quan trọng được đề cập trong bất kỳ bản tìm hiểu nào (mảng rỗng nếu không có).
    - actionItems: danh sách công việc cần thực hiện được đề cập (mỗi mục gồm task, và owner/deadline nếu có nêu; mảng rỗng nếu không có).
    - labels: các nhãn tiêu đề dùng cho ghi chú cuối cùng — generalInfoHeading, dateLabel, topicLabel, participantsLabel, summaryHeading, topicsHeading, decisionsHeading, actionItemsHeading, ownerLabel, deadlineLabel. Mặc định bằng tiếng Việt (ví dụ "Thông tin chung", "Ngày họp", "Chủ đề", "Người tham gia", "Tóm tắt nội dung", "Các chủ đề được thảo luận", "Quyết định quan trọng", "Công việc cần thực hiện", "Người phụ trách", "Deadline"), TRỪ KHI yêu cầu bổ sung bên dưới chỉ định một ngôn ngữ khác — khi đó hãy dịch các nhãn này VÀ mọi trường text ở trên sang đúng ngôn ngữ được yêu cầu.

    Không suy diễn thông tin không có trong các bản tìm hiểu. Không coi nhãn SPEAKER_<number> là tên thật của một người.\(spellingCorrectionInstruction)\(detailAddendum)

    CÁC BẢN TÌM HIỂU THEO CHỦ ĐỀ:
    \(topicFindingsBlock(topicFindings))
    """
}

func parseSynthesisMetadata(from json: Data) -> SynthesisMetadata? {
    struct RawActionItem: Decodable {
        let task: String?
        let owner: String?
        let deadline: String?
    }
    struct RawLabels: Decodable {
        let generalInfoHeading: String?
        let dateLabel: String?
        let topicLabel: String?
        let participantsLabel: String?
        let summaryHeading: String?
        let topicsHeading: String?
        let decisionsHeading: String?
        let actionItemsHeading: String?
        let ownerLabel: String?
        let deadlineLabel: String?
    }
    struct RawMetadata: Decodable {
        let meetingTitle: String?
        let topicSentence: String?
        let participants: [String]?
        let summary: String?
        let decisions: [String]?
        let actionItems: [RawActionItem]?
        let labels: RawLabels?
    }
    guard let raw = try? JSONDecoder().decode(RawMetadata.self, from: json),
          let title = raw.meetingTitle, !title.isEmpty else { return nil }

    let actionItems: [SynthesisActionItem] = (raw.actionItems ?? []).compactMap { item in
        guard let task = item.task, !task.isEmpty else { return nil }
        return SynthesisActionItem(task: task, owner: item.owner, deadline: item.deadline)
    }
    let defaults = SynthesisLabels.defaultVietnamese
    let rawLabels = raw.labels
    let labels = SynthesisLabels(
        generalInfoHeading: rawLabels?.generalInfoHeading ?? defaults.generalInfoHeading,
        dateLabel: rawLabels?.dateLabel ?? defaults.dateLabel,
        topicLabel: rawLabels?.topicLabel ?? defaults.topicLabel,
        participantsLabel: rawLabels?.participantsLabel ?? defaults.participantsLabel,
        summaryHeading: rawLabels?.summaryHeading ?? defaults.summaryHeading,
        topicsHeading: rawLabels?.topicsHeading ?? defaults.topicsHeading,
        decisionsHeading: rawLabels?.decisionsHeading ?? defaults.decisionsHeading,
        actionItemsHeading: rawLabels?.actionItemsHeading ?? defaults.actionItemsHeading,
        ownerLabel: rawLabels?.ownerLabel ?? defaults.ownerLabel,
        deadlineLabel: rawLabels?.deadlineLabel ?? defaults.deadlineLabel
    )

    return SynthesisMetadata(
        meetingTitle: title,
        topicSentence: raw.topicSentence ?? "",
        participants: raw.participants ?? [],
        summary: raw.summary ?? "",
        decisions: raw.decisions ?? [],
        actionItems: actionItems,
        labels: labels
    )
}

/// Deterministically assembles the final note: header/summary/decisions/action-items come
/// from `metadata`, but every topic's body is pasted in exactly as explore/expand wrote it —
/// never re-generated, so it can never be compressed away.
func assembleFinalNote(
    today: String,
    metadata: SynthesisMetadata,
    topicFindings: [(title: String, content: String)]
) -> String {
    var lines: [String] = []
    lines.append("# \(metadata.meetingTitle)")
    lines.append("")
    lines.append("## \(metadata.labels.generalInfoHeading)")
    lines.append("- **\(metadata.labels.dateLabel)**: \(today)")
    lines.append("- **\(metadata.labels.topicLabel)**: \(metadata.topicSentence)")
    let participantsText = metadata.participants.isEmpty ? "—" : metadata.participants.joined(separator: ", ")
    lines.append("- **\(metadata.labels.participantsLabel)**: \(participantsText)")
    lines.append("")
    lines.append("## \(metadata.labels.summaryHeading)")
    lines.append(metadata.summary)
    lines.append("")
    lines.append("## \(metadata.labels.topicsHeading)")
    for (index, item) in topicFindings.enumerated() {
        lines.append("")
        lines.append("### \(index + 1). \(item.title)")
        lines.append(item.content)
    }
    lines.append("")
    lines.append("## \(metadata.labels.decisionsHeading)")
    if metadata.decisions.isEmpty {
        lines.append("- —")
    } else {
        for decision in metadata.decisions { lines.append("- \(decision)") }
    }
    lines.append("")
    lines.append("## \(metadata.labels.actionItemsHeading)")
    if metadata.actionItems.isEmpty {
        lines.append("- —")
    } else {
        for item in metadata.actionItems {
            var line = "- \(item.task)"
            if let owner = item.owner, !owner.isEmpty {
                line += " — \(metadata.labels.ownerLabel): \(owner)"
            }
            if let deadline = item.deadline, !deadline.isEmpty {
                line += ", \(metadata.labels.deadlineLabel): \(deadline)"
            }
            lines.append(line)
        }
    }
    return lines.joined(separator: "\n") + "\n"
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
        progress: @escaping @Sendable (TranscriptionProgress) -> Void,
        trace: @escaping LLMTraceFunc = noopTrace
    ) async throws -> String {
        let preferences = NoteDetailPreferences.loadSaved()
        let detailAddendum = preferences.promptAddendum
        Log.write("[note-tree] start — transcript=\(transcript.count) chars, level=\(preferences.level), addendum=\(detailAddendum.isEmpty ? "(empty)" : detailAddendum.replacingOccurrences(of: "\n", with: " "))")

        func fallbackToSingleCall(reason: String) async throws -> String {
            Log.write("[note-tree] FALLBACK — \(reason)")
            progress(TranscriptionProgress(
                stage: .meetingNote,
                currentSegment: 0,
                totalSegments: 0,
                message: "\(reason) — falling back to a single-call note."
            ))
            let prompt = Self.meetingNotePrompt(today: meetingDate, detailAddendum: detailAddendum) + "\n" + transcript
            Log.write("[note-tree] fallback prompt (non-transcript portion): \(Self.meetingNotePrompt(today: meetingDate, detailAddendum: detailAddendum))")
            let result = try await generateText(parts: [["text": prompt]], systemInstruction: memoryContext, apiKey: apiKey)
            Log.write("[note-tree] fallback response (\(result.count) chars): \(result)")
            await trace("fallback", prompt, result, true)
            return result
        }

        progress(TranscriptionProgress(
            stage: .meetingNote,
            currentSegment: 0,
            totalSegments: 0,
            message: "Decomposing the transcript into topics…"
        ))

        Log.write("[note-tree] decompose prompt template (transcript appended after): \(decomposePrompt(transcript: "<TRANSCRIPT>", detailAddendum: detailAddendum))")
        var decomposeAttemptError: String?
        let decomposeJSON = try? await withRetry(operation: {
            do {
                return try await self.generateStructuredJSON(
                    prompt: decomposePrompt(transcript: transcript, detailAddendum: detailAddendum),
                    schema: decomposeSchema(),
                    systemInstruction: memoryContext,
                    apiKey: apiKey
                )
            } catch {
                decomposeAttemptError = "\(error)"
                throw error
            }
        })
        let decomposePromptText = decomposePrompt(transcript: transcript, detailAddendum: detailAddendum)
        if let decomposeJSON, let raw = String(data: decomposeJSON, encoding: .utf8) {
            Log.write("[note-tree] decompose raw response: \(raw)")
            await trace("decompose", decomposePromptText, raw, true)
        } else {
            Log.write("[note-tree] decompose call FAILED — \(decomposeAttemptError ?? "unknown error")")
            await trace("decompose", decomposePromptText, decomposeAttemptError ?? "unknown error", false)
        }
        guard
            let decomposeJSON,
            let decomposition = parseDecomposition(from: decomposeJSON)
        else {
            return try await fallbackToSingleCall(reason: "Could not decompose the transcript")
        }
        Log.write("[note-tree] parsed \(decomposition.topics.count) topics: \(decomposition.topics.map { "\($0.title) (richness=\($0.richness))" }.joined(separator: ", "))")

        let survivingTopics = selectTopicsForExploration(decomposition.topics, level: preferences.level)
        Log.write("[note-tree] \(survivingTopics.count) topics survive pruning for level \(preferences.level): \(survivingTopics.map(\.title).joined(separator: ", "))")
        guard !survivingTopics.isEmpty else {
            return try await fallbackToSingleCall(reason: "No topics were substantial enough to explore")
        }

        progress(TranscriptionProgress(
            stage: .meetingNote,
            currentSegment: 0,
            totalSegments: survivingTopics.count,
            message: "Exploring \(survivingTopics.count) topic\(survivingTopics.count == 1 ? "" : "s")…"
        ))

        let exploreCounter = ProgressCounter()
        let exploreResults: [String?] = await runBounded(survivingTopics, maxConcurrent: 3) { topic in
            let exploreP = explorePrompt(topic: topic, transcript: transcript, detailAddendum: detailAddendum)
            let text: String?
            do {
                text = try await withRetry {
                    try await self.generateText(
                        parts: [["text": exploreP]],
                        systemInstruction: memoryContext,
                        apiKey: apiKey
                    )
                }
                Log.write("[note-tree] explore[\(topic.title)] response (\(text?.count ?? 0) chars): \(text ?? "")")
                await trace("explore[\(topic.title)]", exploreP, text ?? "", true)
            } catch {
                text = nil
                Log.write("[note-tree] explore[\(topic.title)] FAILED — \(error)")
                await trace("explore[\(topic.title)]", exploreP, "\(error)", false)
            }
            let completed = await exploreCounter.increment()
            progress(TranscriptionProgress(
                stage: .meetingNote,
                currentSegment: completed,
                totalSegments: survivingTopics.count,
                message: "Explored topic \(completed) of \(survivingTopics.count): \(topic.title)"
            ))
            return text
        }

        var findings: [(title: String, content: String)] = zip(survivingTopics, exploreResults).compactMap { topic, text in
            guard let text else { return nil }
            return (topic.title, text)
        }
        guard !findings.isEmpty else {
            return try await fallbackToSingleCall(reason: "Every topic exploration failed")
        }

        let expansionCandidates = selectTopicsForExpansion(from: survivingTopics, level: preferences.level)
        if !expansionCandidates.isEmpty {
            progress(TranscriptionProgress(
                stage: .meetingNote,
                currentSegment: survivingTopics.count,
                totalSegments: survivingTopics.count,
                message: "Deepening \(expansionCandidates.count) topic\(expansionCandidates.count == 1 ? "" : "s")…"
            ))
            let expandResults: [(String, String)?] = await runBounded(expansionCandidates, maxConcurrent: 3) { topic in
                guard let prior = findings.first(where: { $0.title == topic.title })?.content else { return nil }
                let expandP = expandPrompt(topic: topic, priorFindings: prior, transcript: transcript, detailAddendum: detailAddendum)
                do {
                    let deeper = try await withRetry {
                        try await self.generateText(
                            parts: [["text": expandP]],
                            systemInstruction: memoryContext,
                            apiKey: apiKey
                        )
                    }
                    Log.write("[note-tree] expand[\(topic.title)] response (\(deeper.count) chars): \(deeper)")
                    await trace("expand[\(topic.title)]", expandP, deeper, true)
                    return (topic.title, deeper)
                } catch {
                    Log.write("[note-tree] expand[\(topic.title)] FAILED — \(error)")
                    await trace("expand[\(topic.title)]", expandP, "\(error)", false)
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
            totalSegments: survivingTopics.count,
            message: "Writing the summary and action items…"
        ))

        let metadataPrompt = synthesizeMetadataPrompt(
            today: meetingDate,
            meetingTitleGuess: decomposition.meetingTitleGuess,
            participantsGuess: decomposition.participantsGuess,
            topicFindings: findings,
            detailAddendum: detailAddendum
        )
        Log.write("[note-tree] synthesize-metadata prompt (\(metadataPrompt.count) chars): \(metadataPrompt)")
        let metadataJSON = try? await withRetry(operation: {
            try await self.generateStructuredJSON(prompt: metadataPrompt, schema: synthesizeMetadataSchema(), systemInstruction: memoryContext, apiKey: apiKey)
        })
        if let metadataJSON, let raw = String(data: metadataJSON, encoding: .utf8) {
            Log.write("[note-tree] synthesize-metadata raw response: \(raw)")
            await trace("synthesize-metadata", metadataPrompt, raw, true)
        }
        let metadata: SynthesisMetadata
        if let metadataJSON, let parsed = parseSynthesisMetadata(from: metadataJSON) {
            metadata = parsed
        } else {
            Log.write("[note-tree] synthesize-metadata FAILED — assembling with default header labels")
            await trace("synthesize-metadata", metadataPrompt, "parse failed or call failed", false)
            metadata = SynthesisMetadata(
                meetingTitle: (decomposition.meetingTitleGuess?.isEmpty == false) ? decomposition.meetingTitleGuess! : "Meeting Note",
                topicSentence: "",
                participants: decomposition.participantsGuess,
                summary: "",
                decisions: [],
                actionItems: [],
                labels: .defaultVietnamese
            )
        }
        let result = assembleFinalNote(today: meetingDate, metadata: metadata, topicFindings: findings)
        Log.write("[note-tree] final assembled note (\(result.count) chars)")
        return result
    }
}
