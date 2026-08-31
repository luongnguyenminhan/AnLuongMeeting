import CryptoKit
import Foundation

public struct NoteEmbedding: Codable, Sendable {
    public static let currentModel = "gemini-embedding-2"

    public let vector: [Double]
    public let noteTextHash: String
    public let model: String

    public init(vector: [Double], noteTextHash: String, model: String) {
        self.vector = vector
        self.noteTextHash = noteTextHash
        self.model = model
    }
}

public struct NoteEmbeddingStore: Sendable {
    private let fileURL: URL
    private let fileManager: FileManager

    public init(directory: URL, fileManager: FileManager = .default) {
        self.fileURL = directory.appendingPathComponent("embedding.json")
        self.fileManager = fileManager
    }

    public func load() -> NoteEmbedding? {
        guard let raw = fileManager.contents(atPath: fileURL.path) else { return nil }
        return try? JSONDecoder().decode(NoteEmbedding.self, from: raw)
    }

    public func save(_ embedding: NoteEmbedding) throws {
        let data = try JSONEncoder().encode(embedding)
        try data.write(to: fileURL, options: .atomic)
    }
}

/// A stable digest of a note's text, used to detect whether a note changed since it was last
/// embedded — recomputing an embedding for unchanged text would waste an API call for no benefit.
public func noteTextHash(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
}

/// Computes and persists a meeting note's embedding if it's missing or stale (the note text
/// changed since the last embedding). Fails silently on any error — this is best-effort
/// background enrichment. Shared by the note-generation pipeline (called after every note
/// generation/regeneration) and `RecallAgent` (called as a backfill before ranking).
@discardableResult
public func refreshNoteEmbedding(meetingNoteURL: URL, service: GeminiTranscriptionService, apiKey: String) async -> Bool {
    guard let note = try? String(contentsOf: meetingNoteURL, encoding: .utf8) else { return false }
    let store = NoteEmbeddingStore(directory: meetingNoteURL.deletingLastPathComponent())
    let hash = noteTextHash(note)
    if let existing = store.load(), existing.noteTextHash == hash, existing.model == NoteEmbedding.currentModel { return true }
    do {
        let vector = try await service.embedContent(text: note, apiKey: apiKey)
        try store.save(NoteEmbedding(vector: vector, noteTextHash: hash, model: NoteEmbedding.currentModel))
        return true
    } catch {
        return false
    }
}
