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
