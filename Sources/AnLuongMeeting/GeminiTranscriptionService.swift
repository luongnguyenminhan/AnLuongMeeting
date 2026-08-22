import Foundation
@preconcurrency import AVFoundation

enum TranscriptionProgressStage: Sendable {
    case segment
    case meetingNote
}

struct TranscriptionProgress: Sendable {
    let stage: TranscriptionProgressStage
    let currentSegment: Int
    let totalSegments: Int
}

struct TranscriptionResult: Sendable {
    let transcriptURL: URL
    let meetingNoteURL: URL
}

enum RegenerationMode: Sendable {
    case transcriptOnly
    case noteOnly
    case both
}

enum GeminiTranscriptionError: LocalizedError {
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

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Enter a Gemini API key before recording."
        case .invalidDuration:
            return "The recording has no readable duration."
        case .exportUnavailable:
            return "AnLuong Meeting could not create an audio segment exporter."
        case .exportFailed(let message):
            return "Could not create an audio segment: \(message)"
        case .fileTooLarge:
            return "The audio segment is too large to upload."
        case .invalidResponse(let message):
            return "Gemini returned an unexpected response: \(message)"
        case .requestFailed(let message):
            return "Gemini request failed: \(message)"
        case .remoteProcessingFailed:
            return "Gemini could not process an uploaded audio segment."
        case .emptyTranscript(let segment):
            return "Gemini returned no transcript for segment \(segment)."
        case .meetingNoteFailed(let message):
            return "Transcript saved, but meeting note generation failed: \(message)"
        }
    }
}

actor GeminiTranscriptionService {
    private static let chunkDuration: TimeInterval = 20 * 60
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

    private static func meetingNotePrompt(today: String) -> String {
        return """
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

    BẢN CHÉP LỜI:
    """
    }

    private struct RemoteFile: Sendable {
        let name: String
        let uri: String
        let mimeType: String
        let state: String
    }

    func transcribe(
        recordingURL: URL,
        apiKey: String,
        progress: @escaping @Sendable (TranscriptionProgress) -> Void
    ) async throws -> TranscriptionResult {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw GeminiTranscriptionError.missingAPIKey }

        let asset = AVURLAsset(url: recordingURL)
        let duration = (try await asset.load(.duration)).seconds
        guard duration.isFinite, duration > 0 else {
            throw GeminiTranscriptionError.invalidDuration
        }

        let totalSegments = max(1, Int(ceil(duration / Self.chunkDuration)))
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AnLuongMeeting-Transcription-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        var transcripts: [String] = []
        transcripts.reserveCapacity(totalSegments)

        for index in 0..<totalSegments {
            try Task.checkCancellation()

            let start = Double(index) * Self.chunkDuration
            let length = min(Self.chunkDuration, duration - start)
            let segmentURL = temporaryDirectory
                .appendingPathComponent(String(format: "segment-%03d.m4a", index + 1))

            let timeRange = CMTimeRange(
                start: CMTime(seconds: start, preferredTimescale: 600),
                duration: CMTime(seconds: length, preferredTimescale: 600)
            )
            try await export(asset: asset, timeRange: timeRange, to: segmentURL)

            progress(TranscriptionProgress(
                stage: .segment,
                currentSegment: index + 1,
                totalSegments: totalSegments
            ))

            let transcript = try await transcribeSegment(
                segmentURL: segmentURL,
                apiKey: key,
                segmentNumber: index + 1
            )
            transcripts.append(transcript)
        }

        let mergedTranscript = transcripts.joined(separator: "\n\n") + "\n"
        let transcriptURL = recordingURL.deletingPathExtension().appendingPathExtension("txt")
        try Data(mergedTranscript.utf8).write(to: transcriptURL, options: .atomic)

        progress(TranscriptionProgress(
            stage: .meetingNote,
            currentSegment: totalSegments,
            totalSegments: totalSegments
        ))

        let meetingNote: String
        do {
            meetingNote = try await generateMeetingNote(
                transcript: mergedTranscript,
                apiKey: key,
                meetingDate: Self.todayString()
            )
        } catch {
            throw GeminiTranscriptionError.meetingNoteFailed(error.localizedDescription)
        }

        let meetingNoteURL = recordingURL
            .deletingPathExtension()
            .appendingPathExtension("meeting-notes.txt")
        do {
            try Data((meetingNote.trimmingCharacters(in: .whitespacesAndNewlines) + "\n").utf8)
                .write(to: meetingNoteURL, options: .atomic)
        } catch {
            throw GeminiTranscriptionError.meetingNoteFailed(error.localizedDescription)
        }

        return TranscriptionResult(
            transcriptURL: transcriptURL,
            meetingNoteURL: meetingNoteURL
        )
    }

    /// Transcribe audio only — produces a .txt transcript file, no meeting note.
    func transcribeOnly(
        recordingURL: URL,
        apiKey: String,
        progress: @escaping @Sendable (TranscriptionProgress) -> Void
    ) async throws -> URL {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw GeminiTranscriptionError.missingAPIKey }

        let asset = AVURLAsset(url: recordingURL)
        let duration = (try await asset.load(.duration)).seconds
        guard duration.isFinite, duration > 0 else {
            throw GeminiTranscriptionError.invalidDuration
        }

        let totalSegments = max(1, Int(ceil(duration / Self.chunkDuration)))
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AnLuongMeeting-Transcription-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        var transcripts: [String] = []
        transcripts.reserveCapacity(totalSegments)

        for index in 0..<totalSegments {
            try Task.checkCancellation()

            let start = Double(index) * Self.chunkDuration
            let length = min(Self.chunkDuration, duration - start)
            let segmentURL = temporaryDirectory
                .appendingPathComponent(String(format: "segment-%03d.m4a", index + 1))

            let timeRange = CMTimeRange(
                start: CMTime(seconds: start, preferredTimescale: 600),
                duration: CMTime(seconds: length, preferredTimescale: 600)
            )
            try await export(asset: asset, timeRange: timeRange, to: segmentURL)

            progress(TranscriptionProgress(
                stage: .segment,
                currentSegment: index + 1,
                totalSegments: totalSegments
            ))

            let transcript = try await transcribeSegment(
                segmentURL: segmentURL,
                apiKey: key,
                segmentNumber: index + 1
            )
            transcripts.append(transcript)
        }

        let mergedTranscript = transcripts.joined(separator: "\n\n") + "\n"
        let transcriptURL = recordingURL.deletingPathExtension().appendingPathExtension("txt")
        try Data(mergedTranscript.utf8).write(to: transcriptURL, options: .atomic)
        return transcriptURL
    }

    /// Generate a meeting note from an existing transcript file.
    func regenerateNote(
        transcriptURL: URL,
        recordingURL: URL,
        apiKey: String
    ) async throws -> URL {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw GeminiTranscriptionError.missingAPIKey }

        let transcript = try String(contentsOf: transcriptURL, encoding: .utf8)
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GeminiTranscriptionError.emptyTranscript(0)
        }

        let meetingNote = try await generateMeetingNote(
            transcript: transcript,
            apiKey: key,
            meetingDate: Self.todayString()
        )

        let meetingNoteURL = recordingURL
            .deletingPathExtension()
            .appendingPathExtension("meeting-notes.txt")
        try Data((meetingNote.trimmingCharacters(in: .whitespacesAndNewlines) + "\n").utf8)
            .write(to: meetingNoteURL, options: .atomic)
        return meetingNoteURL
    }

    private func transcribeSegment(
        segmentURL: URL,
        apiKey: String,
        segmentNumber: Int
    ) async throws -> String {
        let remoteFile = try await uploadAndWait(fileURL: segmentURL, apiKey: apiKey)

        do {
            let transcript = try await generateTranscript(
                remoteFile: remoteFile,
                apiKey: apiKey
            )
            let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw GeminiTranscriptionError.emptyTranscript(segmentNumber)
            }
            await deleteRemoteFile(named: remoteFile.name, apiKey: apiKey)
            return trimmed
        } catch {
            await deleteRemoteFile(named: remoteFile.name, apiKey: apiKey)
            throw error
        }
    }

    private func uploadAndWait(fileURL: URL, apiKey: String) async throws -> RemoteFile {
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        guard let fileSize = (attributes[.size] as? NSNumber)?.int64Value,
              fileSize > 0 else {
            throw GeminiTranscriptionError.fileTooLarge
        }

        let mimeType = "audio/mp4"
        var startRequest = URLRequest(url: apiURL(path: "upload/v1beta/files", apiKey: apiKey))
        startRequest.httpMethod = "POST"
        startRequest.setValue("resumable", forHTTPHeaderField: "X-Goog-Upload-Protocol")
        startRequest.setValue("start", forHTTPHeaderField: "X-Goog-Upload-Command")
        startRequest.setValue(String(fileSize), forHTTPHeaderField: "X-Goog-Upload-Header-Content-Length")
        startRequest.setValue(mimeType, forHTTPHeaderField: "X-Goog-Upload-Header-Content-Type")
        startRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        startRequest.httpBody = try JSONSerialization.data(withJSONObject: [
            "file": ["display_name": fileURL.lastPathComponent]
        ])

        let (_, startResponse) = try await URLSession.shared.data(for: startRequest)
        let startHTTPResponse = try validate(startResponse)
        guard let uploadURLString = startHTTPResponse.value(forHTTPHeaderField: "X-Goog-Upload-URL"),
              let uploadURL = URL(string: uploadURLString) else {
            throw GeminiTranscriptionError.invalidResponse("Gemini did not return an upload URL.")
        }

        var uploadRequest = URLRequest(url: uploadURL)
        uploadRequest.httpMethod = "POST"
        uploadRequest.setValue("0", forHTTPHeaderField: "X-Goog-Upload-Offset")
        uploadRequest.setValue("upload, finalize", forHTTPHeaderField: "X-Goog-Upload-Command")
        uploadRequest.setValue(mimeType, forHTTPHeaderField: "Content-Type")

        let (data, uploadResponse) = try await URLSession.shared.upload(
            for: uploadRequest,
            fromFile: fileURL
        )
        try validate(uploadResponse)
        return try parseRemoteFile(data)
    }

    private func waitForActiveFile(
        _ file: RemoteFile,
        apiKey: String
    ) async throws -> RemoteFile {
        var current = file
        while current.state == "PROCESSING" {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            current = try await fetchRemoteFile(named: current.name, apiKey: apiKey)
        }

        guard current.state != "FAILED" else {
            throw GeminiTranscriptionError.remoteProcessingFailed
        }
        return current
    }

    private func generateTranscript(
        remoteFile: RemoteFile,
        apiKey: String
    ) async throws -> String {
        let activeFile = try await waitForActiveFile(remoteFile, apiKey: apiKey)
        return try await generateText(
            parts: [
                ["text": Self.transcriptionPrompt],
                ["file_data": [
                    "mime_type": activeFile.mimeType,
                    "file_uri": activeFile.uri
                ]]
            ],
            apiKey: apiKey
        )
    }

    private func generateMeetingNote(
        transcript: String,
        apiKey: String,
        meetingDate: String
    ) async throws -> String {
        return try await generateText(
            parts: [[
                "text": Self.meetingNotePrompt(today: meetingDate) + "\n" + transcript
            ]],
            apiKey: apiKey
        )
    }

    private static func todayString() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "vi_VN")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "dd/MM/yyyy"
        return formatter.string(from: Date())
    }

    private func generateText(
        parts: [[String: Any]],
        apiKey: String
    ) async throws -> String {
        let url = apiURL(
            path: "v1beta/models/\(Self.model):generateContent",
            apiKey: apiKey
        )
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "contents": [["parts": parts]]
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response, data: data)

        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = root["candidates"] as? [[String: Any]],
              let firstCandidate = candidates.first,
              let content = firstCandidate["content"] as? [String: Any],
              let responseParts = content["parts"] as? [[String: Any]] else {
            throw GeminiTranscriptionError.invalidResponse("No text candidate was returned.")
        }

        let text = responseParts.compactMap { $0["text"] as? String }.joined()
        guard !text.isEmpty else {
            throw GeminiTranscriptionError.invalidResponse("The text response was empty.")
        }
        return text
    }

    private func fetchRemoteFile(named name: String, apiKey: String) async throws -> RemoteFile {
        let request = URLRequest(url: apiURL(path: "v1beta/\(name)", apiKey: apiKey))
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response, data: data)
        return try parseRemoteFile(data)
    }

    private func deleteRemoteFile(named name: String, apiKey: String) async {
        var request = URLRequest(url: apiURL(path: "v1beta/\(name)", apiKey: apiKey))
        request.httpMethod = "DELETE"
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode) else {
                Log.write("could not delete Gemini file \(name)")
                return
            }
        } catch {
            Log.write("could not delete Gemini file \(name) — \(error.localizedDescription)")
        }
    }

    private func parseRemoteFile(_ data: Data) throws -> RemoteFile {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GeminiTranscriptionError.invalidResponse("File response was not JSON.")
        }
        let file = (root["file"] as? [String: Any]) ?? root
        guard let name = file["name"] as? String,
              let uri = file["uri"] as? String else {
            throw GeminiTranscriptionError.invalidResponse("File response did not include name or URI.")
        }
        return RemoteFile(
            name: name,
            uri: uri,
            mimeType: file["mimeType"] as? String ?? "audio/mp4",
            state: file["state"] as? String ?? "ACTIVE"
        )
    }

    private func apiURL(path: String, apiKey: String) -> URL {
        var components = URLComponents(string: "https://generativelanguage.googleapis.com/\(path)")!
        components.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        return components.url!
    }

    @discardableResult
    private func validate(_ response: URLResponse, data: Data? = nil) throws -> HTTPURLResponse {
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            let message = data.flatMap { extractErrorMessage(from: $0) }
                ?? HTTPURLResponse.localizedString(forStatusCode: (response as? HTTPURLResponse)?.statusCode ?? 0)
            throw GeminiTranscriptionError.requestFailed(message)
        }
        return httpResponse
    }

    private func extractErrorMessage(from data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = root["error"] as? [String: Any] else {
            return nil
        }
        return error["message"] as? String
    }

    private func export(
        asset: AVAsset,
        timeRange: CMTimeRange,
        to outputURL: URL
    ) async throws {
        guard let exporter = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetPassthrough
        ) else {
            throw GeminiTranscriptionError.exportUnavailable
        }

        exporter.outputURL = outputURL
        exporter.outputFileType = .m4a
        exporter.timeRange = timeRange

        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                exporter.exportAsynchronously {
                    switch exporter.status {
                    case .completed:
                        continuation.resume()
                    case .cancelled:
                        continuation.resume(throwing: CancellationError())
                    default:
                        continuation.resume(throwing: GeminiTranscriptionError.exportFailed(
                            exporter.error?.localizedDescription ?? "unknown export error"
                        ))
                    }
                }
            }
        }, onCancel: {
            exporter.cancelExport()
        })
    }
}
