import CryptoKit
import Foundation

struct NoteEmbedding: Codable, Sendable {
    static let currentModel = "text-embedding-004"

    let vector: [Double]
    let noteTextHash: String
    let model: String
}

struct NoteEmbeddingStore: Sendable {
    private let fileURL: URL
    private let fileManager: FileManager

    init(directory: URL, fileManager: FileManager = .default) {
        self.fileURL = directory.appendingPathComponent("embedding.json")
        self.fileManager = fileManager
    }

    func load() -> NoteEmbedding? {
        guard let raw = fileManager.contents(atPath: fileURL.path) else { return nil }
        return try? JSONDecoder().decode(NoteEmbedding.self, from: raw)
    }

    func save(_ embedding: NoteEmbedding) throws {
        let data = try JSONEncoder().encode(embedding)
        try data.write(to: fileURL, options: .atomic)
    }
}

/// A stable digest of a note's text, used to detect whether a note changed since it was last
/// embedded — recomputing an embedding for unchanged text would waste an API call for no benefit.
func noteTextHash(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
}

/// Computes and persists a meeting note's embedding if it's missing or stale (the note text
/// changed since the last embedding). Fails silently on any error — this is best-effort
/// background enrichment, matching how `RecordingEngine.refreshMemorySuggestions` already treats
/// per-meeting failures as non-blocking. Shared by `RecordingEngine` (called after every note
/// generation/regeneration) and `RecallAgent` (called as a backfill before ranking).
func refreshNoteEmbedding(meetingNoteURL: URL, service: GeminiTranscriptionService, apiKey: String) async {
    guard let note = try? String(contentsOf: meetingNoteURL, encoding: .utf8) else { return }
    let store = NoteEmbeddingStore(directory: meetingNoteURL.deletingLastPathComponent())
    let hash = noteTextHash(note)
    if let existing = store.load(), existing.noteTextHash == hash { return }
    guard let vector = try? await service.embedContent(text: note, apiKey: apiKey) else { return }
    try? store.save(NoteEmbedding(vector: vector, noteTextHash: hash, model: NoteEmbedding.currentModel))
}
