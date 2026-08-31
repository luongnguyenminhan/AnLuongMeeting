import Foundation

/// A persisted turn in the Recall conversation. Mirrors `RecallMessage`'s shape but as a plain
/// `Codable` value — kept separate so the view's own message type stays free to add view-only
/// state later without touching the storage format.
struct RecallStoredMessage: Codable, Sendable, Equatable {
    enum Role: String, Codable, Sendable {
        case user, assistant
    }

    let role: Role
    let text: String
    let citedMeetingIDs: [String]
}

/// Persists the single continuous Recall conversation to `<directory>/recall-conversation.json`,
/// following the same one-JSON-file-per-concern shape as `MemoryStore`. Capped at the most recent
/// 50 messages so the file never grows unbounded over the life of the app.
struct RecallConversationStore: Sendable {
    static let maxStoredMessages = 50

    private let fileURL: URL
    private let fileManager: FileManager

    init(directory: URL, fileManager: FileManager = .default) {
        self.fileURL = directory.appendingPathComponent("recall-conversation.json")
        self.fileManager = fileManager
    }

    func load() -> [RecallStoredMessage] {
        guard let raw = fileManager.contents(atPath: fileURL.path) else { return [] }
        return (try? JSONDecoder().decode([RecallStoredMessage].self, from: raw)) ?? []
    }

    func save(_ messages: [RecallStoredMessage]) throws {
        let trimmed = messages.suffix(Self.maxStoredMessages)
        let data = try JSONEncoder().encode(Array(trimmed))
        try data.write(to: fileURL, options: .atomic)
    }

    func clear() throws {
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        try fileManager.removeItem(at: fileURL)
    }
}
