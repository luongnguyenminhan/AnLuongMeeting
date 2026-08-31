import Foundation

struct RecallAnswer: Sendable {
    let text: String
    let citedMeetingIDs: [String]
}

/// One prior question/answer pair, for giving a follow-up question conversational context (so
/// "what about the deadline?" can resolve what "it" refers to).
struct RecallTurn: Sendable {
    let question: String
    let answerText: String
}

struct RecallAgent: Sendable {
    let service: GeminiTranscriptionService

    private static let topK = 5
    private static let maxHistoryTurns = 3

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
    - Format with real Markdown, not plain lines: use "## " for each section/category heading \
      (never a plain line ending in a colon), "**bold**" for key terms or short labels within a \
      sentence, and "- " for bullet points. Keep it concise — short sections, not walls of text.
    - The user turn may include recent conversation history before the new question — use it only \
      to resolve references like "it" or "that", never as a source of facts by itself.
    - Wrap the entire final answer, and nothing else, between <answer> and </answer> tags. Example \
      shape: <answer>## Business\\n- Point one (Meeting A)\\n- Point two (Meeting B)\\n\\n## \
      Research\\n- Point three (Meeting A)</answer>
    """

    /// Answers `question` using only the top-matching meeting notes: embeds `question`, ranks
    /// every meeting with a note by cosine similarity, and streams Gemini's synthesis of an
    /// answer from the top 5 notes' full text, citing which meeting each fact came from.
    /// `onDelta` is invoked with each new fragment of visible answer text as it streams in (the
    /// model's own reasoning/self-correction never reaches it — see `AnswerTagStreamBuffer`).
    func answer(
        question: String,
        history: [RecallTurn],
        meetings: [MeetingRecord],
        apiKey: String,
        onDelta: @escaping @Sendable (String) -> Void
    ) async throws -> RecallAnswer {
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
        \(Self.renderHistory(history))QUESTION: \(question)

        MEETING NOTES:
        \(contextSections.joined(separator: "\n\n"))
        """

        var buffer = AnswerTagStreamBuffer()
        var fullText = ""

        try await service.streamText(
            parts: [["text": prompt]],
            systemInstruction: Self.systemInstruction,
            model: GeminiTranscriptionService.recallModel,
            apiKey: apiKey
        ) { delta in
            let visible = buffer.append(delta)
            guard !visible.isEmpty else { return }
            fullText += visible
            onDelta(visible)
        }

        let tail = buffer.finish()
        if !tail.isEmpty {
            fullText += tail
            onDelta(tail)
        }

        return RecallAnswer(text: fullText, citedMeetingIDs: ranked.map(\.id))
    }

    /// Renders the last few turns as plain text context ahead of the new question. Returns an
    /// empty string (not even a header) when there's no history, so the prompt shape for a
    /// first question is unchanged from before multi-turn support existed.
    static func renderHistory(_ history: [RecallTurn]) -> String {
        let recent = history.suffix(maxHistoryTurns)
        guard !recent.isEmpty else { return "" }
        let rendered = recent.map { "User: \($0.question)\nAssistant: \($0.answerText)" }.joined(separator: "\n\n")
        return "CONVERSATION SO FAR:\n\(rendered)\n\n"
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
