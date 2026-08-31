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

/// A single targeted find/replace edit proposed against a meeting note's Markdown text —
/// the same "old string -> new string" shape a coding agent's edit tool uses, so a caller can
/// render a diff and apply only what's approved.
public struct NoteEditPatch: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public let oldString: String
    public let newString: String
    public let explanation: String

    public init(oldString: String, newString: String, explanation: String) {
        self.oldString = oldString
        self.newString = newString
        self.explanation = explanation
    }
}

public protocol MeetingTranscriptionService: Sendable {
    func transcribe(
        recordingURL: URL,
        apiKey: String,
        memoryContext: String?,
        glossaryCorrections: [(alias: String, canonical: String)],
        progress: @escaping @Sendable (TranscriptionProgress) -> Void
    ) async throws -> TranscriptionResult

    func transcribeOnly(
        recordingURL: URL,
        apiKey: String,
        memoryContext: String?,
        glossaryCorrections: [(alias: String, canonical: String)],
        progress: @escaping @Sendable (TranscriptionProgress) -> Void
    ) async throws -> URL

    func regenerateNote(
        transcriptURL: URL,
        recordingURL: URL,
        apiKey: String,
        memoryContext: String?,
        glossaryCorrections: [(alias: String, canonical: String)],
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
    private static let model = "gemini-3.5-flash-lite"
    private static let embeddingModel = "gemini-embedding-2"
    static let recallModel = "gemma-4-26b-a4b-it"
    private static let transcriptionPrompt = """
    Listen carefully to the following audio file. PROVIDE A DETAILED TRANSCRIPT WITH SPEAKER DIARIZATION, TRANSCRIBED VERBATIM IN WHATEVER LANGUAGE(S) ARE ACTUALLY SPOKEN — do not translate; transcribe each speaker's words in their original language.
    Focus on speaker diarization and provide a detailed transcript.
    reduce the line of speech, only insert new line if new speaker start speaking.
    Focus on matching the voice to a correct speaker.
      Format:
      SPEAKER_<number>:
      <transcript that you hear>


    If you not hear any speak, just said there is no speaker in the audio, skip the background noise, only focus on the speaker. NO EXTRA INFORMATION NEEDED.
    """

    static func meetingNotePrompt(today: String, detailAddendum: String) -> String {
        baseMeetingNotePrompt(today: today) + detailAddendum + "\n\nTRANSCRIPT:\n"
    }

    private static func baseMeetingNotePrompt(today: String) -> String {
        """
    Create a meeting note in English from the transcript provided below.

    Make sure the summary content:
    1. Has a clear structure, divided into small, easy-to-read sections
    2. Is concise but includes all important information
    3. Uses a professional, natural, easy-to-understand writing style
    4. Skips irrelevant content, focusing on valuable information

    NOTE: DO NOT CREATE NEW INFORMATION, ONLY SUMMARIZE CONTENT THAT WAS ACTUALLY DISCUSSED IN THE MEETING.
    The user confirms the meeting date is today: \(today). You must fill in this exact date under **Meeting Date**, even if the transcript doesn't mention a date. Do not substitute a different date found in the transcript.
    Do not guess the meeting title, participants, decisions, owners, or deadlines. If the transcript has no information, write "Not stated in the transcript" or leave it blank as appropriate for the template.
    Preserve points that are uncertain, differing opinions, and unresolved matters. Do not treat a SPEAKER_<number> label as a person's real name.

    Write naturally, like a professional meeting-minutes writer. Avoid introductions, greetings, compliments, generic closing remarks, AI commentary, promotional content, emojis, and sentences not present in the transcript. Do not use em dashes or hyphens to join sentences. Do not add a "next steps" section if the transcript doesn't state corresponding tasks or decisions.

    REQUIRED FORMAT:
    # [MEETING TITLE]
    ## General Information
    - **Meeting Date**: \(today)
    - **Topic**: [the meeting's main subject]
    - **Participants**: [list of participants if identifiable]

    ## Summary
    [A concise 3-5 sentence summary of the meeting's main content]

    ## Discussed Topics
    1. [Topic 1]
       - [Main point]
       - [Main point]
    2. [Topic 2]
       - [Main point]
       - [Main point]

    ## Key Decisions
    - [Decision 1]
    - [Decision 2]

    ## Action Items
    - [Task 1] - Owner: [Name], Deadline: [Deadline if any]
    - [Task 2] - Owner: [Name], Deadline: [Deadline if any]

    Return only the note content in the exact format above. Don't add any explanation before or after the note.
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
        glossaryCorrections: [(alias: String, canonical: String)] = [],
        progress: @escaping @Sendable (TranscriptionProgress) -> Void = { _ in }
    ) async throws -> TranscriptionResult {
        let key = try validatedAPIKey(apiKey)
        progress(TranscriptionProgress(stage: .segment, currentSegment: 0, totalSegments: 0, message: "Preparing the recording…"))
        let (rawMerged, totalSegments) = try await makeTranscript(
            recordingURL: recordingURL,
            apiKey: key,
            memoryContext: memoryContext,
            progress: progress
        )
        let merged = applyGlossaryCorrections(rawMerged, pairs: glossaryCorrections)
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
        glossaryCorrections: [(alias: String, canonical: String)] = [],
        progress: @escaping @Sendable (TranscriptionProgress) -> Void = { _ in }
    ) async throws -> URL {
        let key = try validatedAPIKey(apiKey)
        progress(TranscriptionProgress(stage: .segment, currentSegment: 0, totalSegments: 0, message: "Preparing the recording…"))
        let (rawMerged, _) = try await makeTranscript(
            recordingURL: recordingURL,
            apiKey: key,
            memoryContext: memoryContext,
            progress: progress
        )
        let merged = applyGlossaryCorrections(rawMerged, pairs: glossaryCorrections)
        let transcriptURL = recordingURL.deletingLastPathComponent().appendingPathComponent("transcript.txt")
        try Data(merged.utf8).write(to: transcriptURL, options: .atomic)
        return transcriptURL
    }

    public func regenerateNote(
        transcriptURL: URL,
        recordingURL: URL,
        apiKey: String,
        memoryContext: String? = nil,
        glossaryCorrections: [(alias: String, canonical: String)] = [],
        progress: @escaping @Sendable (TranscriptionProgress) -> Void = { _ in }
    ) async throws -> URL {
        let key = try validatedAPIKey(apiKey)
        guard let rawTranscript = try? String(contentsOf: transcriptURL, encoding: .utf8),
              !rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GeminiTranscriptionError.emptyTranscript(0)
        }
        let transcript = applyGlossaryCorrections(rawTranscript, pairs: glossaryCorrections)
        if transcript != rawTranscript {
            try? Data(transcript.utf8).write(to: transcriptURL, options: .atomic)
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

    /// One round trip of a multi-turn, tool-calling conversation: sends the full turn history
    /// plus available tools, and returns the model's next turn verbatim (its role and parts,
    /// which may include `functionCall` parts) for the caller to dispatch and continue the loop.
    func generateWithTools(
        contents: [[String: Any]],
        tools: [[String: Any]],
        systemInstruction: String,
        apiKey: String
    ) async throws -> (role: String, parts: [[String: Any]]) {
        let url = baseURL.appendingPathComponent("v1beta/models/\(Self.model):generateContent").appending(queryItems: [URLQueryItem(name: "key", value: apiKey)])
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "contents": contents,
            "tools": tools,
            "system_instruction": ["parts": [["text": systemInstruction]]]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = root["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else {
            throw GeminiTranscriptionError.invalidResponse("Gemini returned no content.")
        }
        return (content["role"] as? String ?? "model", parts)
    }

    static func requestBody(parts: [[String: Any]], systemInstruction: String?) -> [String: Any] {
        var body: [String: Any] = ["contents": [["parts": parts]]]
        if let systemInstruction, !systemInstruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            body["system_instruction"] = ["parts": [["text": systemInstruction]]]
        }
        return body
    }

    /// Streams a text response incrementally via Gemini's server-sent-events endpoint, invoking
    /// `onDelta` with each new text fragment as it arrives.
    func streamText(
        parts: [[String: Any]],
        systemInstruction: String? = nil,
        model: String,
        apiKey: String,
        onDelta: @escaping @Sendable (String) -> Void
    ) async throws {
        let url = baseURL
            .appendingPathComponent("v1beta/models/\(model):streamGenerateContent")
            .appending(queryItems: [URLQueryItem(name: "key", value: apiKey), URLQueryItem(name: "alt", value: "sse")])
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: Self.requestBody(parts: parts, systemInstruction: systemInstruction))

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        try validate(response)

        for try await line in bytes.lines {
            guard line.hasPrefix("data: ") else { continue }
            guard let data = String(line.dropFirst(6)).data(using: .utf8),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let candidates = root["candidates"] as? [[String: Any]],
                  let content = candidates.first?["content"] as? [String: Any],
                  let responseParts = content["parts"] as? [[String: Any]] else { continue }
            // Thinking models (e.g. Gemma) mark internal reasoning parts with "thought": true —
            // skip those so only real output ever reaches onDelta. Models that don't set this
            // field never include it, so this is a no-op for them.
            let text = responseParts
                .filter { ($0["thought"] as? Bool) != true }
                .compactMap { $0["text"] as? String }
                .joined()
            if !text.isEmpty { onDelta(text) }
        }
    }

    /// Embeds `text` into a fixed-size vector for semantic similarity search — used to find
    /// which past meetings are relevant to a Recall question without re-reading every note.
    func embedContent(text: String, apiKey: String) async throws -> [Double] {
        let url = baseURL
            .appendingPathComponent("v1beta/models/\(Self.embeddingModel):embedContent")
            .appending(queryItems: [URLQueryItem(name: "key", value: apiKey)])
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "models/\(Self.embeddingModel)",
            "content": ["parts": [["text": text]]]
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let embedding = root["embedding"] as? [String: Any],
              let values = embedding["values"] as? [Double] else {
            throw GeminiTranscriptionError.invalidResponse("No embedding was returned.")
        }
        return values
    }

    func generateStructuredJSON(prompt: String, schema: [String: Any], systemInstruction: String? = nil, apiKey: String) async throws -> Data {
        let url = baseURL.appendingPathComponent("v1beta/models/\(Self.model):generateContent").appending(queryItems: [URLQueryItem(name: "key", value: apiKey)])
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body = Self.requestBody(parts: [["text": prompt]], systemInstruction: systemInstruction)
        body["generationConfig"] = [
            "responseMimeType": "application/json",
            "responseSchema": schema
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
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
        You are helping a meeting-note app learn new vocabulary and participants.
        Current memory (already confirmed, do NOT suggest these again):
        \(currentMemory.isEmpty ? "(empty)" : currentMemory)

        Compare the transcript and meeting note below against the current memory. Suggest AT MOST 10 NEW entries per category:
        - glossary: proper nouns/project names/domain-specific terms that clearly appear and aren't already in memory.
        - participants: participant names that clearly appear and aren't already in memory.
        - stylePreferences: ONLY suggest if the note shows a notable recurring structure/format.
        - corrections: words/phrases in the MEETING NOTE that are likely a speech-recognition (ASR) error for a term or name already in the current memory (including the known variants listed above). For each error, give the exact wrong text as it appears in the note (wrongText), the correct text from memory (correctText), and other candidates if uncertain (alternatives).
        - identityMerges: if multiple different names in the transcript/note likely refer to the same person, suggest merging them (names, at least 2) and the fullest/most official name if identifiable (canonicalName).

        Don't guess, don't infer. If there's no reliable entry for a category, return an empty array for it.

        TRANSCRIPT:
        \(transcript)

        MEETING NOTE:
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
