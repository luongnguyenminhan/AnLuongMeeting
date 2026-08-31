import Foundation

struct RecallAnswer: Sendable {
    let text: String
    let citedMeetingIDs: [String]
}

struct RecallAgent: Sendable {
    let service: GeminiTranscriptionService

    private static let topK = 5

    private static let systemInstruction = """
    You are a retrieval assistant answering questions about a user's own past meetings, using \
    only the meeting notes given to you in the user turn.

    Rules:
    - Output ONLY the final answer. Never show reasoning, planning, drafts, self-corrections, a \
      restated question, a list of constraints, or any commentary about how you produced the answer.
    - For every concrete fact, name the meeting it came from in parentheses, e.g. (Weekly Platform \
      and Product Development Sync).
    - If the notes don't contain the answer, say so in one short sentence instead of guessing.
    - Answer in the same language as the question.
    - Use short paragraphs or Markdown bullet points. Keep it concise.
    - Wrap the entire final answer, and nothing else, between <answer> and </answer> tags.
    """

    /// Answers `question` using only the top-matching meeting notes: embeds `question`, ranks
    /// every meeting with a note by cosine similarity, and asks Gemini to synthesize an answer
    /// from the top 5 notes' full text, citing which meeting each fact came from.
    func answer(question: String, meetings: [MeetingRecord], apiKey: String) async throws -> RecallAnswer {
        for meeting in meetings {
            guard let noteURL = meeting.meetingNoteURL else { continue }
            await refreshNoteEmbedding(meetingNoteURL: noteURL, service: service, apiKey: apiKey)
        }

        let indexed: [(meeting: MeetingRecord, vector: [Double])] = meetings.compactMap { meeting in
            guard let noteURL = meeting.meetingNoteURL,
                  let embedding = NoteEmbeddingStore(directory: noteURL.deletingLastPathComponent()).load() else { return nil }
            return (meeting, embedding.vector)
        }
        guard !indexed.isEmpty else {
            return RecallAnswer(text: "No meeting notes are available to search yet.", citedMeetingIDs: [])
        }

        let questionVector = try await service.embedContent(text: question, apiKey: apiKey)
        let rankedIDs = Self.topMatches(
            query: questionVector,
            candidates: indexed.map { (id: $0.meeting.id, vector: $0.vector) },
            limit: Self.topK
        )
        let ranked = rankedIDs.compactMap { id in indexed.first { $0.meeting.id == id }?.meeting }

        let contextSections = ranked.compactMap { meeting -> String? in
            guard let noteURL = meeting.meetingNoteURL,
                  let note = try? String(contentsOf: noteURL, encoding: .utf8) else { return nil }
            return "### \(meeting.displayName)\n\(note)"
        }

        let prompt = """
        QUESTION: \(question)

        MEETING NOTES:
        \(contextSections.joined(separator: "\n\n"))
        """

        let raw = try await service.generateText(
            parts: [["text": prompt]],
            systemInstruction: Self.systemInstruction,
            model: GeminiTranscriptionService.recallModel,
            apiKey: apiKey
        )
        return RecallAnswer(text: Self.extractAnswer(from: raw), citedMeetingIDs: ranked.map(\.id))
    }

    /// Pulls the text between `<answer>`/`</answer>` tags, which the system prompt instructs the
    /// model to wrap its final answer in. Falls back to the raw (trimmed) response if the model
    /// didn't use the tags — some models occasionally skip them for a short answer — so a
    /// malformed response still shows something instead of an empty bubble.
    static func extractAnswer(from raw: String) -> String {
        guard let openRange = raw.range(of: "<answer>"),
              let closeRange = raw.range(of: "</answer>", range: openRange.upperBound..<raw.endIndex) else {
            return raw.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return String(raw[openRange.upperBound..<closeRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func cosineSimilarity(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot = 0.0
        var normA = 0.0
        var normB = 0.0
        for index in a.indices {
            dot += a[index] * b[index]
            normA += a[index] * a[index]
            normB += b[index] * b[index]
        }
        guard normA > 0, normB > 0 else { return 0 }
        return dot / (normA.squareRoot() * normB.squareRoot())
    }

    static func topMatches(query: [Double], candidates: [(id: String, vector: [Double])], limit: Int) -> [String] {
        candidates
            .sorted { cosineSimilarity(query, $0.vector) > cosineSimilarity(query, $1.vector) }
            .prefix(limit)
            .map(\.id)
    }
}
