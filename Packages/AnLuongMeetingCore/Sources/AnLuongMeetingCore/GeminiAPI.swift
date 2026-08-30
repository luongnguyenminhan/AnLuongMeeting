import Foundation
@preconcurrency import AVFoundation

public enum TranscriptionProgressStage: Sendable {
    case segment
    case meetingNote
}

public struct TranscriptionProgress: Sendable {
    public let stage: TranscriptionProgressStage
    public let currentSegment: Int
    public let totalSegments: Int
    public let message: String

    public init(
        stage: TranscriptionProgressStage,
        currentSegment: Int,
        totalSegments: Int,
        message: String = ""
    ) {
        self.stage = stage
        self.currentSegment = currentSegment
        self.totalSegments = totalSegments
        self.message = message
    }
}

public struct TranscriptionResult: Sendable {
    public let transcriptURL: URL
    public let meetingNoteURL: URL

    public init(transcriptURL: URL, meetingNoteURL: URL) {
        self.transcriptURL = transcriptURL
        self.meetingNoteURL = meetingNoteURL
    }
}

public protocol MeetingTranscriptionService: Sendable {
    func transcribe(
        recordingURL: URL,
        apiKey: String,
        memoryContext: String?,
        progress: @escaping @Sendable (TranscriptionProgress) -> Void
    ) async throws -> TranscriptionResult

    func transcribeOnly(
        recordingURL: URL,
        apiKey: String,
        memoryContext: String?,
        progress: @escaping @Sendable (TranscriptionProgress) -> Void
    ) async throws -> URL

    func regenerateNote(
        transcriptURL: URL,
        recordingURL: URL,
        apiKey: String,
        memoryContext: String?,
        progress: @escaping @Sendable (TranscriptionProgress) -> Void
    ) async throws -> URL

    func suggestMemoryUpdates(
        transcript: String,
        note: String,
        currentMemory: String,
        apiKey: String
    ) async throws -> MemoryDraft
}

public enum GeminiRegenerationMode: String, CaseIterable, Equatable, Sendable {
    case transcriptOnly
    case noteOnly
    case both
}

public enum GeminiTranscriptionError: LocalizedError, Equatable, Sendable {
    case missingAPIKey
    case invalidDuration
    case exportUnavailable
    case exportFailed(String)
    case fileTooLarge
    case invalidResponse(String)
    case requestFailed(String)
    case remoteProcessingFailed
    case emptyTranscript(Int)
    case meetingNoteFailed(String)
    case rateLimited(retryAfter: TimeInterval?)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "Enter a Gemini API key before processing a recording."
        case .invalidDuration: return "The recording has no readable duration."
        case .exportUnavailable: return "AnLuongMeeting could not create an audio segment exporter."
        case .exportFailed(let message): return "Could not create an audio segment: \(message)"
        case .fileTooLarge: return "The audio segment is too large to upload."
        case .invalidResponse(let message): return "Gemini returned an unexpected response: \(message)"
        case .requestFailed(let message): return "Gemini request failed: \(message)"
        case .remoteProcessingFailed: return "Gemini could not process an uploaded audio segment."
        case .emptyTranscript(let segment): return "Gemini returned no transcript for segment \(segment)."
        case .meetingNoteFailed(let message): return "Transcript saved, but meeting note generation failed: \(message)"
        case .rateLimited(let retryAfter):
            if let retryAfter { return "Gemini rate-limited the request. Retry after \(Int(retryAfter))s." }
            return "Gemini rate-limited the request."
        }
    }
}

public actor GeminiTranscriptionService: MeetingTranscriptionService {
    private static let chunkDuration: TimeInterval = 20 * 60
    private static let remoteProcessingTimeout: TimeInterval = 5 * 60
    private static let model = "gemini-3.1-flash-lite"
    private static let transcriptionPrompt = """
    RESPONSE IN VIETNAMESE: Listen carefully to the following audio file. PROVIDE DETAIL TRANSCRIPT WITH SPEAKER DIARIZATION IN VIETNAMESE
    Listen carefully, focus on speaker diarization, and provide a detailed transcript in Vietnamese.
    reduce the line of speech, only insert new line if new speaker start speaking.
    Focus on matching the voice to a correct speaker.
      Format:
      SPEAKER_<number>:
      <transcript that you hear>


    If you not hear any speak, just said there is no speaker in the audio, skip the background noise, only focus on the speaker. NO EXTRA INFORMATION NEEDED.
    """

    static func meetingNotePrompt(today: String, detailAddendum: String) -> String {
        baseMeetingNotePrompt(today: today) + detailAddendum + "\n\nBẢN CHÉP LỜI:\n"
    }

    private static func baseMeetingNotePrompt(today: String) -> String {
        """
    Hãy tạo ghi chú cuộc họp bằng tiếng Việt từ bản chép lời được cung cấp sau đây.

    Hãy đảm bảo nội dung tóm tắt:
    1. Có cấu trúc rõ ràng, chia thành các phần nhỏ dễ đọc
    2. Ngắn gọn nhưng đầy đủ thông tin quan trọng
    3. Sử dụng văn phong chuyên nghiệp, tự nhiên, dễ hiểu
    4. Bỏ qua các nội dung không liên quan, tập trung vào các thông tin có giá trị

    CHÚ Ý: KHÔNG TẠO THÔNG TIN MỚI, CHỈ TÓM TẮT CÁC NỘI DUNG ĐÃ ĐƯỢC THẢO LUẬN TRONG CUỘC HỌP.
    Người dùng xác nhận ngày họp là hôm nay: \(today). Bắt buộc điền đúng ngày này vào mục **Ngày họp**, ngay cả khi transcript không nhắc đến ngày. Không thay thế bằng ngày khác trong transcript.
    Không được đoán tên cuộc họp, người tham gia, quyết định, người phụ trách hoặc thời hạn. Nếu transcript không có thông tin, ghi rõ "Không nêu trong bản chép lời" hoặc để trống phù hợp với mẫu.
    Giữ nguyên các điểm chưa chắc chắn, ý kiến khác nhau và việc chưa được giải quyết. Không coi nhãn SPEAKER_<number> là tên thật của một người.

    Hãy viết tự nhiên như một người ghi biên bản chuyên nghiệp. Tránh lời mở đầu, lời chào, lời khen, lời kết chung chung, nhận xét của AI, nội dung quảng cáo, emoji và các câu không có trong transcript. Không dùng dấu gạch ngang dài hoặc dấu gạch ngang ngắn để nối câu. Không thêm phần "bước tiếp theo" nếu transcript không nêu công việc hoặc quyết định tương ứng.

    ĐỊNH DẠNG BẮT BUỘC:
    # [TÊN CUỘC HỌP]
    ## Thông tin chung
    - **Ngày họp**: \(today)
    - **Chủ đề**: [chủ đề chính của cuộc họp]
    - **Người tham gia**: [danh sách người tham gia nếu có thể xác định]

    ## Tóm tắt nội dung
    [Tóm tắt ngắn gọn 3-5 câu về nội dung chính của cuộc họp]

    ## Các chủ đề được thảo luận
    1. [Chủ đề 1]
       - [Điểm chính]
       - [Điểm chính]
    2. [Chủ đề 2]
       - [Điểm chính]
       - [Điểm chính]

    ## Quyết định quan trọng
    - [Quyết định 1]
    - [Quyết định 2]

    ## Công việc cần thực hiện
    - [Công việc 1] - Người phụ trách: [Tên], Deadline: [Thời hạn nếu có]
    - [Công việc 2] - Người phụ trách: [Tên], Deadline: [Thời hạn nếu có]

    Chỉ trả về nội dung ghi chú theo đúng định dạng trên. Không thêm lời giải thích trước hoặc sau ghi chú.
    """
    }
    private let baseURL = URL(string: "https://generativelanguage.googleapis.com")!

    public init() {}

    /// Performs a small authenticated model metadata request without uploading a recording.
    public func testAPIKey(apiKey: String) async throws {
        let key = try validatedAPIKey(apiKey)
        let url = baseURL
            .appendingPathComponent("v1beta/models/\(Self.model)")
            .appending(queryItems: [URLQueryItem(name: "key", value: key)])
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let (_, response) = try await URLSession.shared.data(for: request)
        try validate(response)
    }

    public func transcribe(
        recordingURL: URL,
        apiKey: String,
        memoryContext: String? = nil,
        progress: @escaping @Sendable (TranscriptionProgress) -> Void = { _ in }
    ) async throws -> TranscriptionResult {
        let key = try validatedAPIKey(apiKey)
        progress(TranscriptionProgress(stage: .segment, currentSegment: 0, totalSegments: 0, message: "Preparing the recording…"))
        let (merged, totalSegments) = try await makeTranscript(
            recordingURL: recordingURL,
            apiKey: key,
            memoryContext: memoryContext,
            progress: progress
        )
        let transcriptURL = recordingURL.deletingLastPathComponent().appendingPathComponent("transcript.txt")
        try Data(merged.utf8).write(to: transcriptURL, options: .atomic)
        progress(TranscriptionProgress(stage: .meetingNote, currentSegment: totalSegments, totalSegments: totalSegments, message: "Transcript saved. Generating the meeting note…"))
        let noteURL = try await writeMeetingNote(
            transcript: merged,
            recordingURL: recordingURL,
            apiKey: key,
            memoryContext: memoryContext,
            progress: progress,
            totalSegments: totalSegments
        )
        return TranscriptionResult(transcriptURL: transcriptURL, meetingNoteURL: noteURL)
    }

    public func transcribeOnly(
        recordingURL: URL,
        apiKey: String,
        memoryContext: String? = nil,
        progress: @escaping @Sendable (TranscriptionProgress) -> Void = { _ in }
    ) async throws -> URL {
        let key = try validatedAPIKey(apiKey)
        progress(TranscriptionProgress(stage: .segment, currentSegment: 0, totalSegments: 0, message: "Preparing the recording…"))
        let (merged, _) = try await makeTranscript(
            recordingURL: recordingURL,
            apiKey: key,
            memoryContext: memoryContext,
            progress: progress
        )
        let transcriptURL = recordingURL.deletingLastPathComponent().appendingPathComponent("transcript.txt")
        try Data(merged.utf8).write(to: transcriptURL, options: .atomic)
        return transcriptURL
    }

    public func regenerateNote(
        transcriptURL: URL,
        recordingURL: URL,
        apiKey: String,
        memoryContext: String? = nil,
        progress: @escaping @Sendable (TranscriptionProgress) -> Void = { _ in }
    ) async throws -> URL {
        let key = try validatedAPIKey(apiKey)
        guard let transcript = try? String(contentsOf: transcriptURL, encoding: .utf8),
              !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GeminiTranscriptionError.emptyTranscript(0)
        }
        progress(TranscriptionProgress(stage: .meetingNote, currentSegment: 0, totalSegments: 0, message: "Generating the meeting note…"))
        return try await writeMeetingNote(
            transcript: transcript,
            recordingURL: recordingURL,
            apiKey: key,
            memoryContext: memoryContext,
            progress: progress,
            totalSegments: 0
        )
    }

    public func suggestMemoryUpdates(
        transcript: String,
        note: String,
        currentMemory: String,
        apiKey: String
    ) async throws -> MemoryDraft {
        let key = try validatedAPIKey(apiKey)
        let json = try await generateStructuredJSON(
            prompt: Self.memorySuggestionPrompt(transcript: transcript, note: note, currentMemory: currentMemory),
            schema: Self.memorySuggestionSchema(),
            apiKey: key
        )
        return Self.parseMemoryDraft(from: json)
    }

    private func validatedAPIKey(_ apiKey: String) throws -> String {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw GeminiTranscriptionError.missingAPIKey }
        return key
    }

    private func makeTranscript(
        recordingURL: URL,
        apiKey: String,
        memoryContext: String?,
        progress: @escaping @Sendable (TranscriptionProgress) -> Void
    ) async throws -> (String, Int) {
        let asset = AVURLAsset(url: recordingURL)
        let duration = (try await asset.load(.duration)).seconds
        guard duration.isFinite, duration > 0 else { throw GeminiTranscriptionError.invalidDuration }

        let totalSegments = max(1, Int(ceil(duration / Self.chunkDuration)))
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AnLuongMeeting-Transcription-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        var transcripts: [String] = []
        transcripts.reserveCapacity(totalSegments)
        for index in 0..<totalSegments {
            try Task.checkCancellation()
            let segmentNumber = index + 1
            let start = Double(index) * Self.chunkDuration
            let length = min(Self.chunkDuration, duration - start)
            let segmentURL = tempDirectory.appendingPathComponent(String(format: "segment-%03d.m4a", segmentNumber))
            let range = CMTimeRange(
                start: CMTime(seconds: start, preferredTimescale: 600),
                duration: CMTime(seconds: length, preferredTimescale: 600)
            )
            progress(TranscriptionProgress(
                stage: .segment,
                currentSegment: segmentNumber,
                totalSegments: totalSegments,
                message: "Exporting audio segment \(segmentNumber) of \(totalSegments)…"
            ))
            try await export(asset: asset, timeRange: range, to: segmentURL)
            transcripts.append(try await transcribeSegment(
                segmentURL: segmentURL,
                apiKey: apiKey,
                memoryContext: memoryContext,
                segmentNumber: segmentNumber,
                totalSegments: totalSegments,
                progress: progress
            ))
            progress(TranscriptionProgress(
                stage: .segment,
                currentSegment: segmentNumber,
                totalSegments: totalSegments,
                message: "Finished segment \(segmentNumber) of \(totalSegments)."
            ))
        }
        return (transcripts.joined(separator: "\n\n") + "\n", totalSegments)
    }

    private func writeMeetingNote(
        transcript: String,
        recordingURL: URL,
        apiKey: String,
        memoryContext: String?,
        progress: @escaping @Sendable (TranscriptionProgress) -> Void,
        totalSegments: Int
    ) async throws -> URL {
        let note: String
        do {
            note = try await generateMeetingNote(transcript: transcript, memoryContext: memoryContext, apiKey: apiKey, progress: progress)
        } catch {
            throw GeminiTranscriptionError.meetingNoteFailed(error.localizedDescription)
        }
        let noteURL = recordingURL.deletingLastPathComponent().appendingPathComponent("notes.txt")
        do {
            try Data((note.trimmingCharacters(in: .whitespacesAndNewlines) + "\n").utf8)
                .write(to: noteURL, options: .atomic)
        } catch {
            throw GeminiTranscriptionError.meetingNoteFailed(error.localizedDescription)
        }
        progress(TranscriptionProgress(
            stage: .meetingNote,
            currentSegment: totalSegments,
            totalSegments: totalSegments,
            message: "Meeting note saved."
        ))
        return noteURL
    }

    private struct RemoteFile: Sendable {
        let name: String
        let uri: String
        let mimeType: String
        let state: String
    }

    private func transcribeSegment(
        segmentURL: URL,
        apiKey: String,
        memoryContext: String?,
        segmentNumber: Int,
        totalSegments: Int,
        progress: @escaping @Sendable (TranscriptionProgress) -> Void
    ) async throws -> String {
        progress(TranscriptionProgress(
            stage: .segment,
            currentSegment: segmentNumber,
            totalSegments: totalSegments,
            message: "Uploading segment \(segmentNumber) to Gemini…"
        ))
        let remoteFile = try await uploadAndWait(fileURL: segmentURL, apiKey: apiKey)
        defer { Task { await deleteRemoteFile(named: remoteFile.name, apiKey: apiKey) } }
        progress(TranscriptionProgress(
            stage: .segment,
            currentSegment: segmentNumber,
            totalSegments: totalSegments,
            message: "Waiting for Gemini to prepare segment \(segmentNumber)…"
        ))
        let active = try await waitForActiveFile(
            remoteFile,
            apiKey: apiKey,
            segmentNumber: segmentNumber,
            totalSegments: totalSegments,
            progress: progress
        )
        progress(TranscriptionProgress(
            stage: .segment,
            currentSegment: segmentNumber,
            totalSegments: totalSegments,
            message: "Transcribing segment \(segmentNumber) of \(totalSegments)…"
        ))
        let text = try await generateText(
            parts: [
                ["text": Self.transcriptionPrompt],
                ["file_data": ["mime_type": active.mimeType, "file_uri": active.uri]]
            ],
            systemInstruction: memoryContext,
            apiKey: apiKey
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw GeminiTranscriptionError.emptyTranscript(segmentNumber) }
        return text
    }

    private func generateMeetingNote(
        transcript: String,
        memoryContext: String?,
        apiKey: String,
        progress: @escaping @Sendable (TranscriptionProgress) -> Void
    ) async throws -> String {
        try await generateMeetingNoteViaResearchTree(
            transcript: transcript,
            apiKey: apiKey,
            memoryContext: memoryContext,
            meetingDate: Self.todayString(),
            progress: progress
        )
    }

    private func uploadAndWait(fileURL: URL, apiKey: String) async throws -> RemoteFile {
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        guard let size = (attributes[.size] as? NSNumber)?.int64Value, size > 0 else { throw GeminiTranscriptionError.fileTooLarge }
        var request = URLRequest(url: baseURL.appendingPathComponent("upload/v1beta/files").appending(queryItems: [URLQueryItem(name: "key", value: apiKey)]))
        request.httpMethod = "POST"
        request.setValue("resumable", forHTTPHeaderField: "X-Goog-Upload-Protocol")
        request.setValue("start", forHTTPHeaderField: "X-Goog-Upload-Command")
        request.setValue(String(size), forHTTPHeaderField: "X-Goog-Upload-Header-Content-Length")
        request.setValue("audio/mp4", forHTTPHeaderField: "X-Goog-Upload-Header-Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["file": ["display_name": fileURL.lastPathComponent]])
        let (_, response) = try await URLSession.shared.data(for: request)
        try validate(response)
        guard let uploadURLString = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "X-Goog-Upload-URL"), let uploadURL = URL(string: uploadURLString) else {
            throw GeminiTranscriptionError.invalidResponse("Gemini did not return an upload URL.")
        }
        var upload = URLRequest(url: uploadURL)
        upload.httpMethod = "POST"
        upload.setValue("0", forHTTPHeaderField: "X-Goog-Upload-Offset")
        upload.setValue("upload, finalize", forHTTPHeaderField: "X-Goog-Upload-Command")
        upload.setValue("audio/mp4", forHTTPHeaderField: "Content-Type")
        let (data, uploadResponse) = try await URLSession.shared.upload(for: upload, fromFile: fileURL)
        try validate(uploadResponse)
        return try parseRemoteFile(data)
    }

    private func waitForActiveFile(
        _ file: RemoteFile,
        apiKey: String,
        segmentNumber: Int,
        totalSegments: Int,
        progress: @escaping @Sendable (TranscriptionProgress) -> Void
    ) async throws -> RemoteFile {
        var current = file
        let startedAt = Date()
        var delay: UInt64 = 1
        while current.state == "PROCESSING" {
            try Task.checkCancellation()
            guard Date().timeIntervalSince(startedAt) < Self.remoteProcessingTimeout else {
                throw GeminiTranscriptionError.requestFailed("Gemini audio processing timed out after 5 minutes.")
            }
            try await Task.sleep(nanoseconds: delay * 1_000_000_000)
            current = try await fetchRemoteFile(named: current.name, apiKey: apiKey)
            if current.state == "PROCESSING" {
                progress(TranscriptionProgress(
                    stage: .segment,
                    currentSegment: segmentNumber,
                    totalSegments: totalSegments,
                    message: "Still preparing segment \(segmentNumber)…"
                ))
            }
            delay = min(delay + 1, 5)
        }
        guard current.state != "FAILED" else { throw GeminiTranscriptionError.remoteProcessingFailed }
        return current
    }

    private func fetchRemoteFile(named name: String, apiKey: String) async throws -> RemoteFile {
        let url = baseURL.appendingPathComponent("v1beta/\(name)").appending(queryItems: [URLQueryItem(name: "key", value: apiKey)])
        let (data, response) = try await URLSession.shared.data(from: url)
        try validate(response)
        return try parseRemoteFile(data)
    }

    func generateText(parts: [[String: Any]], systemInstruction: String? = nil, apiKey: String) async throws -> String {
        let url = baseURL.appendingPathComponent("v1beta/models/\(Self.model):generateContent").appending(queryItems: [URLQueryItem(name: "key", value: apiKey)])
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: Self.requestBody(parts: parts, systemInstruction: systemInstruction))
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = root["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let responseParts = content["parts"] as? [[String: Any]],
              let text = responseParts.compactMap({ $0["text"] as? String }).first else {
            throw GeminiTranscriptionError.invalidResponse("Gemini returned no text.")
        }
        return text
    }

    static func requestBody(parts: [[String: Any]], systemInstruction: String?) -> [String: Any] {
        var body: [String: Any] = ["contents": [["parts": parts]]]
        if let systemInstruction, !systemInstruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            body["system_instruction"] = ["parts": [["text": systemInstruction]]]
        }
        return body
    }

    func generateStructuredJSON(prompt: String, schema: [String: Any], apiKey: String) async throws -> Data {
        let url = baseURL.appendingPathComponent("v1beta/models/\(Self.model):generateContent").appending(queryItems: [URLQueryItem(name: "key", value: apiKey)])
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "contents": [["parts": [["text": prompt]]]],
            "generationConfig": [
                "responseMimeType": "application/json",
                "responseSchema": schema
            ]
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = root["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let responseParts = content["parts"] as? [[String: Any]],
              let text = responseParts.compactMap({ $0["text"] as? String }).first,
              let textData = text.data(using: .utf8) else {
            throw GeminiTranscriptionError.invalidResponse("Gemini returned no structured JSON.")
        }
        return textData
    }

    private static func memorySuggestionSchema() -> [String: Any] {
        let glossaryItem: [String: Any] = [
            "type": "OBJECT",
            "properties": [
                "term": ["type": "STRING"],
                "category": ["type": "STRING", "enum": ["project", "jargon"]],
                "confidence": ["type": "NUMBER"],
                "snippet": ["type": "STRING"]
            ],
            "required": ["term", "category", "confidence", "snippet"]
        ]
        let participantItem: [String: Any] = [
            "type": "OBJECT",
            "properties": [
                "name": ["type": "STRING"],
                "confidence": ["type": "NUMBER"],
                "snippet": ["type": "STRING"]
            ],
            "required": ["name", "confidence", "snippet"]
        ]
        let styleItem: [String: Any] = [
            "type": "OBJECT",
            "properties": [
                "note": ["type": "STRING"],
                "confidence": ["type": "NUMBER"],
                "snippet": ["type": "STRING"]
            ],
            "required": ["note", "confidence", "snippet"]
        ]
        let correctionItem: [String: Any] = [
            "type": "OBJECT",
            "properties": [
                "wrongText": ["type": "STRING"],
                "correctText": ["type": "STRING"],
                "alternatives": ["type": "ARRAY", "items": ["type": "STRING"]],
                "kind": ["type": "STRING", "enum": ["glossaryTerm", "participantName"]],
                "confidence": ["type": "NUMBER"],
                "snippet": ["type": "STRING"]
            ],
            "required": ["wrongText", "correctText", "kind", "confidence", "snippet"]
        ]
        let identityMergeItem: [String: Any] = [
            "type": "OBJECT",
            "properties": [
                "names": ["type": "ARRAY", "items": ["type": "STRING"]],
                "canonicalName": ["type": "STRING"],
                "confidence": ["type": "NUMBER"],
                "snippet": ["type": "STRING"]
            ],
            "required": ["names", "confidence", "snippet"]
        ]
        return [
            "type": "OBJECT",
            "properties": [
                "glossary": ["type": "ARRAY", "items": glossaryItem],
                "participants": ["type": "ARRAY", "items": participantItem],
                "stylePreferences": ["type": "ARRAY", "items": styleItem],
                "corrections": ["type": "ARRAY", "items": correctionItem],
                "identityMerges": ["type": "ARRAY", "items": identityMergeItem]
            ],
            "required": ["glossary", "participants", "stylePreferences", "corrections", "identityMerges"]
        ]
    }

    private static func memorySuggestionPrompt(transcript: String, note: String, currentMemory: String) -> String {
        """
        Bạn đang giúp một ứng dụng ghi chú cuộc họp học thêm từ vựng và người tham gia mới.
        Bộ nhớ hiện tại (đã xác nhận, KHÔNG đề xuất lại các mục này):
        \(currentMemory.isEmpty ? "(trống)" : currentMemory)

        So sánh bản chép lời và ghi chú cuộc họp bên dưới với bộ nhớ hiện tại. Đề xuất TỐI ĐA 10 mục MỚI cho mỗi loại:
        - glossary: tên riêng/dự án/thuật ngữ chuyên ngành xuất hiện rõ ràng, chưa có trong bộ nhớ.
        - participants: tên người tham gia xuất hiện rõ ràng, chưa có trong bộ nhớ.
        - stylePreferences: CHỈ đề xuất nếu ghi chú cho thấy một cấu trúc/định dạng lặp lại đáng chú ý.
        - corrections: các từ/cụm từ trong GHI CHÚ CUỘC HỌP có khả năng là lỗi nhận dạng giọng nói (ASR) của một thuật ngữ hoặc tên đã có trong bộ nhớ hiện tại (kể cả các biến thể đã biết ở trên). Với mỗi lỗi, ghi rõ văn bản sai (wrongText) đúng như trong ghi chú, văn bản đúng (correctText) lấy từ bộ nhớ, và các phương án khác nếu không chắc chắn (alternatives).
        - identityMerges: nếu nhiều tên khác nhau trong bản chép lời/ghi chú có khả năng chỉ cùng một người, đề xuất gộp lại (names, ít nhất 2 tên) và tên đầy đủ/chính thức nhất nếu xác định được (canonicalName).

        Không đoán, không suy diễn. Nếu không có mục nào đáng tin cậy cho một loại, trả về mảng rỗng cho loại đó.

        BẢN CHÉP LỜI:
        \(transcript)

        GHI CHÚ CUỘC HỌP:
        \(note)
        """
    }

    static func parseMemoryDraft(from json: Data) -> MemoryDraft {
        struct RawEntry: Decodable {
            let term: String?
            let name: String?
            let note: String?
            let category: String?
            let confidence: Double?
            let snippet: String?
        }
        struct RawCorrection: Decodable {
            let wrongText: String?
            let correctText: String?
            let alternatives: [String]?
            let kind: String?
            let confidence: Double?
            let snippet: String?
        }
        struct RawMerge: Decodable {
            let names: [String]?
            let canonicalName: String?
            let confidence: Double?
            let snippet: String?
        }
        struct RawDraft: Decodable {
            let glossary: [RawEntry]?
            let participants: [RawEntry]?
            let stylePreferences: [RawEntry]?
            let corrections: [RawCorrection]?
            let identityMerges: [RawMerge]?
        }
        guard let raw = try? JSONDecoder().decode(RawDraft.self, from: json) else { return MemoryDraft() }
        let now = Date()

        let glossary: [GlossaryEntry] = (raw.glossary ?? []).compactMap { entry in
            guard let term = entry.term, !term.isEmpty,
                  let categoryRaw = entry.category, let category = GlossaryCategory(rawValue: categoryRaw) else { return nil }
            return GlossaryEntry(term: term, category: category, lastUsedAt: now, source: .suggested, confirmed: false, confidence: entry.confidence, snippet: entry.snippet)
        }
        let participants: [Participant] = (raw.participants ?? []).compactMap { entry in
            guard let name = entry.name, !name.isEmpty else { return nil }
            return Participant(name: name, lastSeenAt: now, source: .suggested, confirmed: false, confidence: entry.confidence, snippet: entry.snippet)
        }
        let styles: [StylePreference] = (raw.stylePreferences ?? []).compactMap { entry in
            guard let note = entry.note, !note.isEmpty else { return nil }
            return StylePreference(note: note, source: .suggested, confirmed: false, confidence: entry.confidence, snippet: entry.snippet)
        }
        let corrections: [NoteCorrection] = (raw.corrections ?? []).compactMap { entry in
            guard let wrongText = entry.wrongText, !wrongText.isEmpty,
                  let correctText = entry.correctText, !correctText.isEmpty,
                  let kindRaw = entry.kind, let kind = CorrectionKind(rawValue: kindRaw) else { return nil }
            return NoteCorrection(wrongText: wrongText, correctText: correctText, alternatives: entry.alternatives ?? [], kind: kind, confidence: entry.confidence, snippet: entry.snippet)
        }
        let identityMerges: [IdentityMergeSuggestion] = (raw.identityMerges ?? []).compactMap { entry in
            guard let names = entry.names, names.count >= 2 else { return nil }
            return IdentityMergeSuggestion(names: names, canonicalName: entry.canonicalName, confidence: entry.confidence, snippet: entry.snippet)
        }
        return MemoryDraft(glossary: glossary, participants: participants, stylePreferences: styles, corrections: corrections, identityMerges: identityMerges)
    }

    private func deleteRemoteFile(named name: String, apiKey: String) async {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1beta/\(name)").appending(queryItems: [URLQueryItem(name: "key", value: apiKey)]))
        request.httpMethod = "DELETE"
        _ = try? await URLSession.shared.data(for: request)
    }

    private func parseRemoteFile(_ data: Data) throws -> RemoteFile {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let file = root["file"] as? [String: Any] ?? (root["name"] != nil ? root : nil),
              let name = file["name"] as? String,
              let uri = file["uri"] as? String,
              let mimeType = file["mimeType"] as? String,
              let state = file["state"] as? String else {
            throw GeminiTranscriptionError.invalidResponse("Gemini returned an invalid file response.")
        }
        return RemoteFile(name: name, uri: uri, mimeType: mimeType, state: state)
    }

    private func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw GeminiTranscriptionError.requestFailed("No HTTP response.")
        }
        if let error = classifyGeminiResponse(http, errorBody: nil) {
            throw error
        }
    }

    private static func todayString() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "vi_VN")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "dd/MM/yyyy"
        return formatter.string(from: Date())
    }

    private func export(asset: AVAsset, timeRange: CMTimeRange, to url: URL) async throws {
        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw GeminiTranscriptionError.exportUnavailable
        }
        exporter.timeRange = timeRange
        exporter.outputURL = url
        exporter.outputFileType = .m4a
        await exporter.export()
        guard exporter.status == .completed else {
            throw GeminiTranscriptionError.exportFailed(exporter.error?.localizedDescription ?? "Unknown export error")
        }
    }
}
