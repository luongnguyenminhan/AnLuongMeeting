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
    let message: String

    init(stage: TranscriptionProgressStage, currentSegment: Int, totalSegments: Int, message: String = "") {
        self.stage = stage
        self.currentSegment = currentSegment
        self.totalSegments = totalSegments
        self.message = message
    }
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

/// A single targeted find/replace edit proposed against a meeting note's Markdown text.
struct NoteEditPatch: Identifiable, Equatable, Sendable {
    let id = UUID()
    let oldString: String
    let newString: String
    let explanation: String
}

enum GeminiTranscriptionError: LocalizedError, Equatable {
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
        case .rateLimited(let retryAfter):
            if let retryAfter { return "Gemini rate-limited the request. Retry after \(Int(retryAfter))s." }
            return "Gemini rate-limited the request."
        }
    }
}

actor GeminiTranscriptionService {
    private static let chunkDuration: TimeInterval = 20 * 60
    private static let model = "gemini-3.1-flash-lite"
    private static let embeddingModel = "gemini-embedding-001"

    private static let transcriptionPrompt = """
    Listen carefully to the following audio file. PROVIDE A DETAILED TRANSCRIPT WITH SPEAKER DIARIZATION, TRANSCRIBED VERBATIM IN WHATEVER LANGUAGE(S) ARE ACTUALLY SPOKEN — do not translate; transcribe each speaker's words in their original language.
    Focus on speaker diarization and provide a detailed transcript.
    reduce the line of speech, only insert new line if new speaker start speaking.
    Focus on matching the voice to a correct speaker.
      Format:
      SPEAKER_<number>:
      <transcript that you hear>


    If you not hear any speak, just said there is no speaker in the audio, skip the background noise, only focus on the speaker. NO EXTRA INFORMATION NEEDED.

    IMPORTANT — known spelling corrections: if the system instruction lists a confirmed term/name together with variants marked "also heard as: ...", and you hear one of those variants in this audio, transcribe it using the confirmed spelling instead of the mishearing. This is fixing a known transcription error, not adding information.
    """

    static func meetingNotePrompt(today: String, detailAddendum: String) -> String {
        baseMeetingNotePrompt(today: today) + spellingCorrectionInstruction + detailAddendum + "\n\nTRANSCRIPT:\n"
    }

    private static func baseMeetingNotePrompt(today: String) -> String {
        return """
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

    private struct RemoteFile: Sendable {
        let name: String
        let uri: String
        let mimeType: String
        let state: String
    }

    func transcribe(
        recordingURL: URL,
        apiKey: String,
        memoryContext: String? = nil,
        glossaryCorrections: [(alias: String, canonical: String)] = [],
        progress: @escaping @Sendable (TranscriptionProgress) -> Void,
        trace: @escaping LLMTraceFunc = noopTrace
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
                totalSegments: totalSegments,
                message: "Transcribing segment \(index + 1) of \(totalSegments)…"
            ))

            let transcript = try await transcribeSegment(
                segmentURL: segmentURL,
                apiKey: key,
                memoryContext: memoryContext,
                segmentNumber: index + 1,
                trace: trace
            )
            transcripts.append(transcript)
        }

        let mergedTranscript = applyGlossaryCorrections(
            transcripts.joined(separator: "\n\n") + "\n",
            pairs: glossaryCorrections
        )
        let transcriptURL = recordingURL.deletingLastPathComponent().appendingPathComponent("transcript.txt")
        try Data(mergedTranscript.utf8).write(to: transcriptURL, options: .atomic)

        let meetingNote: String
        do {
            meetingNote = try await generateMeetingNote(
                transcript: mergedTranscript,
                apiKey: key,
                memoryContext: memoryContext,
                meetingDate: Self.todayString(),
                progress: progress,
                trace: trace
            )
        } catch {
            throw GeminiTranscriptionError.meetingNoteFailed(error.localizedDescription)
        }

        let meetingNoteURL = recordingURL
            .deletingLastPathComponent()
            .appendingPathComponent("notes.txt")
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
        memoryContext: String? = nil,
        glossaryCorrections: [(alias: String, canonical: String)] = [],
        progress: @escaping @Sendable (TranscriptionProgress) -> Void,
        trace: @escaping LLMTraceFunc = noopTrace
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
                totalSegments: totalSegments,
                message: "Transcribing segment \(index + 1) of \(totalSegments)…"
            ))

            let transcript = try await transcribeSegment(
                segmentURL: segmentURL,
                apiKey: key,
                memoryContext: memoryContext,
                segmentNumber: index + 1,
                trace: trace
            )
            transcripts.append(transcript)
        }

        let mergedTranscript = applyGlossaryCorrections(
            transcripts.joined(separator: "\n\n") + "\n",
            pairs: glossaryCorrections
        )
        let transcriptURL = recordingURL.deletingLastPathComponent().appendingPathComponent("transcript.txt")
        try Data(mergedTranscript.utf8).write(to: transcriptURL, options: .atomic)
        return transcriptURL
    }

    /// Generate a meeting note from an existing transcript file.
    func regenerateNote(
        transcriptURL: URL,
        recordingURL: URL,
        apiKey: String,
        memoryContext: String? = nil,
        glossaryCorrections: [(alias: String, canonical: String)] = [],
        progress: @escaping @Sendable (TranscriptionProgress) -> Void = { _ in },
        trace: @escaping LLMTraceFunc = noopTrace
    ) async throws -> URL {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw GeminiTranscriptionError.missingAPIKey }

        let rawTranscript = try String(contentsOf: transcriptURL, encoding: .utf8)
        guard !rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GeminiTranscriptionError.emptyTranscript(0)
        }
        let transcript = applyGlossaryCorrections(rawTranscript, pairs: glossaryCorrections)
        if transcript != rawTranscript {
            try? Data(transcript.utf8).write(to: transcriptURL, options: .atomic)
        }

        let meetingNote = try await generateMeetingNote(
            transcript: transcript,
            apiKey: key,
            memoryContext: memoryContext,
            meetingDate: Self.todayString(),
            progress: progress,
            trace: trace
        )

        let meetingNoteURL = recordingURL
            .deletingLastPathComponent()
            .appendingPathComponent("notes.txt")
        try Data((meetingNote.trimmingCharacters(in: .whitespacesAndNewlines) + "\n").utf8)
            .write(to: meetingNoteURL, options: .atomic)
        return meetingNoteURL
    }

    private func transcribeSegment(
        segmentURL: URL,
        apiKey: String,
        memoryContext: String?,
        segmentNumber: Int,
        trace: @escaping LLMTraceFunc = noopTrace
    ) async throws -> String {
        let remoteFile = try await uploadAndWait(fileURL: segmentURL, apiKey: apiKey)

        do {
            let transcript = try await generateTranscript(
                remoteFile: remoteFile,
                memoryContext: memoryContext,
                apiKey: apiKey
            )
            let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                await trace("transcribe-segment-\(segmentNumber)", Self.transcriptionPrompt, "", false)
                throw GeminiTranscriptionError.emptyTranscript(segmentNumber)
            }
            await trace("transcribe-segment-\(segmentNumber)", Self.transcriptionPrompt, trimmed, true)
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
        memoryContext: String?,
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
            systemInstruction: memoryContext,
            apiKey: apiKey
        )
    }

    private func generateMeetingNote(
        transcript: String,
        apiKey: String,
        memoryContext: String?,
        meetingDate: String,
        progress: @escaping @Sendable (TranscriptionProgress) -> Void,
        trace: @escaping LLMTraceFunc = noopTrace
    ) async throws -> String {
        try await generateMeetingNoteViaResearchTree(
            transcript: transcript,
            apiKey: apiKey,
            memoryContext: memoryContext,
            meetingDate: meetingDate,
            progress: progress,
            trace: trace
        )
    }

    func suggestMemoryUpdates(
        transcript: String,
        note: String,
        currentMemory: String,
        apiKey: String,
        trace: @escaping LLMTraceFunc = noopTrace
    ) async throws -> MemoryDraft {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw GeminiTranscriptionError.missingAPIKey }
        let prompt = Self.memorySuggestionPrompt(transcript: transcript, note: note, currentMemory: currentMemory)
        do {
            let json = try await generateStructuredJSON(prompt: prompt, schema: Self.memorySuggestionSchema(), apiKey: key)
            let raw = String(data: json, encoding: .utf8) ?? ""
            await trace("memory-suggestions", prompt, raw, true)
            return Self.parseMemoryDraft(from: json)
        } catch {
            await trace("memory-suggestions", prompt, "\(error)", false)
            throw error
        }
    }

    func generateStructuredJSON(prompt: String, schema: [String: Any], systemInstruction: String? = nil, apiKey: String) async throws -> Data {
        let url = apiURL(path: "v1beta/models/\(Self.model):generateContent", apiKey: apiKey)
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
        try validate(response, data: data)
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

    private static func todayString() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "vi_VN")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "dd/MM/yyyy"
        return formatter.string(from: Date())
    }

    func generateText(
        parts: [[String: Any]],
        systemInstruction: String? = nil,
        apiKey: String
    ) async throws -> String {
        let url = apiURL(
            path: "v1beta/models/\(Self.model):generateContent",
            apiKey: apiKey
        )
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: Self.requestBody(parts: parts, systemInstruction: systemInstruction))

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

    /// Embeds `text` into a fixed-size vector for semantic similarity search — used to find
    /// which past meetings are relevant to a Recall question without re-reading every note.
    func embedContent(text: String, apiKey: String) async throws -> [Double] {
        let url = apiURL(path: "v1beta/models/\(Self.embeddingModel):embedContent", apiKey: apiKey)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "models/\(Self.embeddingModel)",
            "content": ["parts": [["text": text]]]
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response, data: data)

        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let embedding = root["embedding"] as? [String: Any],
              let values = embedding["values"] as? [Double] else {
            throw GeminiTranscriptionError.invalidResponse("No embedding was returned.")
        }
        return values
    }

    static func requestBody(parts: [[String: Any]], systemInstruction: String?) -> [String: Any] {
        var body: [String: Any] = ["contents": [["parts": parts]]]
        if let systemInstruction, !systemInstruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            body["system_instruction"] = ["parts": [["text": systemInstruction]]]
        }
        return body
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
        let url = apiURL(path: "v1beta/models/\(Self.model):generateContent", apiKey: apiKey)
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
        try validate(response, data: data)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = root["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else {
            throw GeminiTranscriptionError.invalidResponse("Gemini returned no content.")
        }
        return (content["role"] as? String ?? "model", parts)
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
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GeminiTranscriptionError.requestFailed("No HTTP response.")
        }
        if let error = classifyGeminiResponse(httpResponse, errorBody: data) {
            throw error
        }
        return httpResponse
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
