import XCTest
@testable import AnLuongMeeting

final class RecallConversationStoreTests: XCTestCase {
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

    func testLoadReturnsEmptyWhenNothingSaved() {
        XCTAssertEqual(RecallConversationStore(directory: directory).load(), [])
    }

    func testSaveAndLoadRoundTrips() throws {
        let store = RecallConversationStore(directory: directory)
        let messages = [
            RecallStoredMessage(role: .user, text: "What did we decide?", citedMeetingIDs: []),
            RecallStoredMessage(role: .assistant, text: "You decided X.", citedMeetingIDs: ["abc"])
        ]

        try store.save(messages)

        XCTAssertEqual(store.load(), messages)
    }

    func testSaveCapsAtMaxStoredMessagesKeepingTheMostRecent() throws {
        let store = RecallConversationStore(directory: directory)
        let messages = (0..<60).map {
            RecallStoredMessage(role: .user, text: "message \($0)", citedMeetingIDs: [])
        }

        try store.save(messages)
        let loaded = store.load()

        XCTAssertEqual(loaded.count, RecallConversationStore.maxStoredMessages)
        XCTAssertEqual(loaded.first?.text, "message 10")
        XCTAssertEqual(loaded.last?.text, "message 59")
    }

    func testClearRemovesTheStoredFile() throws {
        let store = RecallConversationStore(directory: directory)
        try store.save([RecallStoredMessage(role: .user, text: "hi", citedMeetingIDs: [])])

        try store.clear()

        XCTAssertEqual(store.load(), [])
    }

    func testClearIsSafeWhenNothingWasEverSaved() throws {
        try RecallConversationStore(directory: directory).clear()
    }
}
