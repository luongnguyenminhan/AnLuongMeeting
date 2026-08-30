import XCTest
@testable import AnLuongMeeting

final class MeetingLibraryModelTests: XCTestCase {
    private var fixtureDirectory: URL!
    private let fileManager = FileManager.default

    override func setUpWithError() throws {
        fixtureDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("AnLuongTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)

        try makeFolderMeeting(named: "product-sync", transcript: true, note: true)
        try makeFolderMeeting(named: "partial", transcript: true)
        try Data("unrelated".utf8).write(to: fixtureDirectory.appendingPathComponent("unrelated.txt"))
    }

    override func tearDownWithError() throws {
        if let fixtureDirectory {
            try? fileManager.removeItem(at: fixtureDirectory)
        }
    }

    private func makeFolderMeeting(named name: String, transcript: Bool = false, note: Bool = false, corrections: Bool = false) throws {
        let folder = fixtureDirectory.appendingPathComponent(name, isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: folder.appendingPathComponent("recording.m4a"))
        if transcript { try Data("transcript".utf8).write(to: folder.appendingPathComponent("transcript.txt")) }
        if note { try Data("note".utf8).write(to: folder.appendingPathComponent("notes.txt")) }
        if corrections { try Data("[]".utf8).write(to: folder.appendingPathComponent("corrections.json")) }
    }

    func testScanGroupsKnownArtifactsByMeetingFolder() throws {
        let records = try MeetingLibraryIndex.scan(directory: fixtureDirectory, processingURL: nil)

        XCTAssertEqual(records.map(\.displayName).sorted(), ["partial", "product-sync"])
        let product = try XCTUnwrap(records.first { $0.displayName == "product-sync" })
        XCTAssertNotNil(product.transcriptURL)
        XCTAssertNotNil(product.meetingNoteURL)
        XCTAssertEqual(product.status, .ready)
    }

    func testProcessingOverridesReadyForActiveRecording() throws {
        let activeURL = fixtureDirectory.appendingPathComponent("product-sync").appendingPathComponent("recording.m4a")

        let records = try MeetingLibraryIndex.scan(directory: fixtureDirectory, processingURL: activeURL)

        XCTAssertEqual(records.first { $0.displayName == "product-sync" }?.status, .processing)
    }

    func testScanPopulatesCorrectionsURLOnlyWhenSidecarExists() throws {
        try Data("[]".utf8).write(to: fixtureDirectory.appendingPathComponent("product-sync").appendingPathComponent("corrections.json"))

        let records = try MeetingLibraryIndex.scan(directory: fixtureDirectory, processingURL: nil)

        XCTAssertNotNil(records.first(where: { $0.displayName == "product-sync" })?.correctionsURL)
        XCTAssertNil(records.first(where: { $0.displayName == "partial" })?.correctionsURL)
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

    // MARK: - Migration

    private func writeLegacyFlatMeeting(named name: String, transcript: Bool = true, note: Bool = true, corrections: Bool = true) throws {
        try Data("audio".utf8).write(to: fixtureDirectory.appendingPathComponent("\(name).m4a"))
        if transcript { try Data("transcript".utf8).write(to: fixtureDirectory.appendingPathComponent("\(name).txt")) }
        if note { try Data("note".utf8).write(to: fixtureDirectory.appendingPathComponent("\(name).meeting-notes.txt")) }
        if corrections { try Data("[]".utf8).write(to: fixtureDirectory.appendingPathComponent("\(name).note-corrections.json")) }
    }

    func testMigrationConvertsFlatMeetingIntoFolderFormat() throws {
        try writeLegacyFlatMeeting(named: "legacy")

        let records = try MeetingLibraryIndex.scan(directory: fixtureDirectory, processingURL: nil)

        let folder = fixtureDirectory.appendingPathComponent("legacy", isDirectory: true)
        XCTAssertTrue(fileManager.fileExists(atPath: folder.appendingPathComponent("recording.m4a").path))
        XCTAssertTrue(fileManager.fileExists(atPath: folder.appendingPathComponent("transcript.txt").path))
        XCTAssertTrue(fileManager.fileExists(atPath: folder.appendingPathComponent("notes.txt").path))
        XCTAssertTrue(fileManager.fileExists(atPath: folder.appendingPathComponent("corrections.json").path))
        XCTAssertFalse(fileManager.fileExists(atPath: fixtureDirectory.appendingPathComponent("legacy.m4a").path))
        XCTAssertTrue(records.contains { $0.displayName == "legacy" && $0.status == .ready })
    }

    func testMigrationIsIdempotentAcrossRepeatedScans() throws {
        try writeLegacyFlatMeeting(named: "legacy")

        _ = try MeetingLibraryIndex.scan(directory: fixtureDirectory, processingURL: nil)
        let secondRecords = try MeetingLibraryIndex.scan(directory: fixtureDirectory, processingURL: nil)

        XCTAssertEqual(secondRecords.filter { $0.displayName == "legacy" }.count, 1)
    }

    func testMigrationOfOneFailingMeetingDoesNotAffectAnother() throws {
        try writeLegacyFlatMeeting(named: "blocked")
        try fileManager.createDirectory(at: fixtureDirectory.appendingPathComponent("blocked", isDirectory: true), withIntermediateDirectories: true)
        try writeLegacyFlatMeeting(named: "fine")

        let records = try MeetingLibraryIndex.scan(directory: fixtureDirectory, processingURL: nil)

        XCTAssertTrue(fileManager.fileExists(atPath: fixtureDirectory.appendingPathComponent("blocked.m4a").path))
        XCTAssertTrue(fileManager.fileExists(atPath: fixtureDirectory.appendingPathComponent("fine", isDirectory: true).appendingPathComponent("recording.m4a").path))
        XCTAssertTrue(records.contains { $0.displayName == "fine" })
        XCTAssertFalse(records.contains { $0.displayName == "blocked" })
    }
}
