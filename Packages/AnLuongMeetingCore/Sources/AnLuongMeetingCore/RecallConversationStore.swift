import Foundation

/// A persisted turn in the Recall conversation. Mirrors the view's own message shape but as a
/// plain `Codable` value — kept separate so the view's message type stays free to add view-only
/// state later without touching the storage format.
public struct RecallStoredMessage: Codable, Sendable, Equatable {
    public enum Role: String, Codable, Sendable {
        case user, assistant
    }

    public let role: Role
    public let text: String
    public let citedMeetingIDs: [String]

    public init(role: Role, text: String, citedMeetingIDs: [String]) {
        self.role = role
        self.text = text
        self.citedMeetingIDs = citedMeetingIDs
    }
}

/// Persists the single continuous Recall conversation to `<directory>/recall-conversation.json`,
/// following the same one-JSON-file-per-concern shape as `MemoryStore`. Capped at the most recent
/// 50 messages so the file never grows unbounded over the life of the app.
public struct RecallConversationStore: Sendable {
    public static let maxStoredMessages = 50

    private let fileURL: URL
    private let fileManager: FileManager

    public init(directory: URL, fileManager: FileManager = .default) {
        self.fileURL = directory.appendingPathComponent("recall-conversation.json")
        self.fileManager = fileManager
    }

    public func load() -> [RecallStoredMessage] {
        guard let raw = fileManager.contents(atPath: fileURL.path) else { return [] }
        return (try? JSONDecoder().decode([RecallStoredMessage].self, from: raw)) ?? []
    }

    public func save(_ messages: [RecallStoredMessage]) throws {
        let trimmed = messages.suffix(Self.maxStoredMessages)
        let data = try JSONEncoder().encode(Array(trimmed))
        try data.write(to: fileURL, options: .atomic)
    }

    public func clear() throws {
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        try fileManager.removeItem(at: fileURL)
    }
}
