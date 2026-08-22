import XCTest
@testable import AnLuongMeeting

final class MeetingLibraryModelTests: XCTestCase {
    private var fixtureDirectory: URL!
    private let fileManager = FileManager.default

    override func setUpWithError() throws {
        fixtureDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("AnLuongTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)

        for name in [
            "product-sync.m4a",
            "product-sync.txt",
            "product-sync.meeting-notes.txt",
            "partial.m4a",
            "partial.txt",
            "unrelated.txt"
        ] {
            try Data(name.utf8).write(to: fixtureDirectory.appendingPathComponent(name))
        }
    }

    override func tearDownWithError() throws {
        if let fixtureDirectory {
            try? fileManager.removeItem(at: fixtureDirectory)
        }
    }

    func testScanGroupsKnownArtifactsByRecordingBaseName() throws {
        let records = try MeetingLibraryIndex.scan(directory: fixtureDirectory, processingURL: nil)

        XCTAssertEqual(records.map(\.displayName).sorted(), ["partial", "product-sync"])
        let product = try XCTUnwrap(records.first { $0.displayName == "product-sync" })
        XCTAssertNotNil(product.transcriptURL)
        XCTAssertNotNil(product.meetingNoteURL)
        XCTAssertEqual(product.status, .ready)
    }

    func testProcessingOverridesReadyForActiveRecording() throws {
        let activeURL = fixtureDirectory.appendingPathComponent("product-sync.m4a")

        let records = try MeetingLibraryIndex.scan(directory: fixtureDirectory, processingURL: activeURL)

        XCTAssertEqual(records.first { $0.displayName == "product-sync" }?.status, .processing)
    }

    func testSearchAndFilterAreCaseInsensitiveAndStatusAware() throws {
        let records = try MeetingLibraryIndex.scan(directory: fixtureDirectory, processingURL: nil)

        XCTAssertEqual(
            MeetingLibraryIndex.filtered(records, searchText: "PRODUCT", filter: .ready).map(\.displayName),
            ["product-sync"]
        )
        XCTAssertEqual(
            MeetingLibraryIndex.filtered(records, searchText: "", filter: .partial).map(\.displayName),
            ["partial"]
        )
    }
}
