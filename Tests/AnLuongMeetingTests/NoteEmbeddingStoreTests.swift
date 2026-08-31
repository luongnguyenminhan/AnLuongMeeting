import XCTest
@testable import AnLuongMeeting

final class NoteEmbeddingStoreTests: XCTestCase {
    private var directory: URL!
    private let fileManager = FileManager.default

    override func setUpWithError() throws {
        directory = fileManager.temporaryDirectory
            .appendingPathComponent("AnLuongTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory {
            try? fileManager.removeItem(at: directory)
        }
    }

    func testLoadReturnsNilWhenNoEmbeddingSaved() {
        let store = NoteEmbeddingStore(directory: directory)
        XCTAssertNil(store.load())
    }

    func testSaveAndLoadRoundTripsTheEmbedding() throws {
        let store = NoteEmbeddingStore(directory: directory)
        let embedding = NoteEmbedding(vector: [0.1, 0.2, 0.3], noteTextHash: "abc123", model: NoteEmbedding.currentModel)

        try store.save(embedding)
        let loaded = try XCTUnwrap(store.load())

        XCTAssertEqual(loaded.vector, [0.1, 0.2, 0.3])
        XCTAssertEqual(loaded.noteTextHash, "abc123")
        XCTAssertEqual(loaded.model, NoteEmbedding.currentModel)
    }

    func testNoteTextHashIsStableAndSensitiveToContent() {
        let hashA1 = noteTextHash("Meeting note A")
        let hashA2 = noteTextHash("Meeting note A")
        let hashB = noteTextHash("Meeting note B")

        XCTAssertEqual(hashA1, hashA2)
        XCTAssertNotEqual(hashA1, hashB)
    }
}
