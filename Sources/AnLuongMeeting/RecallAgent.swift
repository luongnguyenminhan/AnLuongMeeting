import Foundation

struct RecallAnswer: Sendable {
    let text: String
    let citedMeetingIDs: [String]
}

struct RecallAgent: Sendable {
    let service: GeminiTranscriptionService

    private static let topK = 5

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
        Answer the question using ONLY the meeting notes below. For every fact you state, name \
        which meeting (by its title) it came from. If the notes don't contain the answer, say so \
        plainly instead of guessing.

        QUESTION: \(question)

        MEETING NOTES:
        \(contextSections.joined(separator: "\n\n"))
        """

        let text = try await service.generateText(
            parts: [["text": prompt]],
            model: GeminiTranscriptionService.recallModel,
            apiKey: apiKey
        )
        return RecallAnswer(text: text, citedMeetingIDs: ranked.map(\.id))
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
