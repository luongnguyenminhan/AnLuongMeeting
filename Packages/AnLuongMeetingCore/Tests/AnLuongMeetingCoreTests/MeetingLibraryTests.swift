import XCTest
@testable import AnLuongMeetingCore

final class MeetingLibraryTests: XCTestCase {
    private var directory: URL!
    private let fileManager = FileManager.default

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("AnLuongCore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeFolderMeeting(named name: String, transcript: Bool = false, note: Bool = false, corrections: Bool = false) throws {
        let folder = directory.appendingPathComponent(name, isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data([0, 1]).write(to: folder.appendingPathComponent("recording.m4a"))
        if transcript { try Data("transcript".utf8).write(to: folder.appendingPathComponent("transcript.txt")) }
        if note { try Data("note".utf8).write(to: folder.appendingPathComponent("notes.txt")) }
        if corrections { try Data("[]".utf8).write(to: folder.appendingPathComponent("corrections.json")) }
    }

    func testScanDerivesReadyPartialAndProcessing() throws {
        try makeFolderMeeting(named: "ready", transcript: true, note: true)
        try makeFolderMeeting(named: "partial")
        try makeFolderMeeting(named: "processing")
        let processingURL = directory.appendingPathComponent("processing").appendingPathComponent("recording.m4a")

        let records = try MeetingLibraryIndex.scan(directory: directory, processingURL: processingURL)
        XCTAssertEqual(records.first(where: { $0.displayName == "ready" })?.status, .ready)
        XCTAssertEqual(records.first(where: { $0.displayName == "partial" })?.status, .partial)
        XCTAssertEqual(records.first(where: { $0.displayName == "processing" })?.status, .processing)
    }

    func testScanPopulatesCorrectionsURLOnlyWhenSidecarExists() throws {
        try makeFolderMeeting(named: "with-corrections", corrections: true)
        try makeFolderMeeting(named: "without-corrections")

        let records = try MeetingLibraryIndex.scan(directory: directory, processingURL: nil)

        XCTAssertNotNil(records.first(where: { $0.displayName == "with-corrections" })?.correctionsURL)
        XCTAssertNil(records.first(where: { $0.displayName == "without-corrections" })?.correctionsURL)
    }

    func testFilterSearchAndStatus() {
        let now = Date()
        let records = [
            MeetingRecord(displayName: "Planning", recordingURL: directory.appendingPathComponent("Planning/recording.m4a"), transcriptURL: nil, meetingNoteURL: nil, modifiedAt: now, duration: nil, status: .ready),
            MeetingRecord(displayName: "Retro", recordingURL: directory.appendingPathComponent("Retro/recording.m4a"), transcriptURL: nil, meetingNoteURL: nil, modifiedAt: now, duration: nil, status: .partial)
        ]
        let result = MeetingLibraryIndex.filtered(records, searchText: "plan", filter: .ready)
        XCTAssertEqual(result.map(\.displayName), ["Planning"])
    }

    // MARK: - Migration

    private func writeLegacyFlatMeeting(named name: String, transcript: Bool = true, note: Bool = true, corrections: Bool = true) throws {
        try Data([0, 1]).write(to: directory.appendingPathComponent("\(name).m4a"))
        if transcript { try Data("transcript".utf8).write(to: directory.appendingPathComponent("\(name).txt")) }
        if note { try Data("note".utf8).write(to: directory.appendingPathComponent("\(name).meeting-notes.txt")) }
        if corrections { try Data("[]".utf8).write(to: directory.appendingPathComponent("\(name).note-corrections.json")) }
    }

    func testMigrationConvertsFlatMeetingIntoFolderFormat() throws {
        try writeLegacyFlatMeeting(named: "legacy")

        let records = try MeetingLibraryIndex.scan(directory: directory, processingURL: nil)

        let folder = directory.appendingPathComponent("legacy", isDirectory: true)
        XCTAssertTrue(fileManager.fileExists(atPath: folder.appendingPathComponent("recording.m4a").path))
        XCTAssertTrue(fileManager.fileExists(atPath: folder.appendingPathComponent("transcript.txt").path))
        XCTAssertTrue(fileManager.fileExists(atPath: folder.appendingPathComponent("notes.txt").path))
        XCTAssertTrue(fileManager.fileExists(atPath: folder.appendingPathComponent("corrections.json").path))
        XCTAssertFalse(fileManager.fileExists(atPath: directory.appendingPathComponent("legacy.m4a").path))
        XCTAssertEqual(records.first?.displayName, "legacy")
        XCTAssertEqual(records.first?.status, .ready)
    }

    func testMigrationIsIdempotentAcrossRepeatedScans() throws {
        try writeLegacyFlatMeeting(named: "legacy")

        _ = try MeetingLibraryIndex.scan(directory: directory, processingURL: nil)
        let secondRecords = try MeetingLibraryIndex.scan(directory: directory, processingURL: nil)

        XCTAssertEqual(secondRecords.count, 1)
        XCTAssertEqual(secondRecords.first?.displayName, "legacy")
    }

    func testMigrationOfOneFailingMeetingDoesNotAffectAnother() throws {
        try writeLegacyFlatMeeting(named: "blocked")
        // Pre-existing destination folder forces this meeting's migration to be skipped.
        try fileManager.createDirectory(at: directory.appendingPathComponent("blocked", isDirectory: true), withIntermediateDirectories: true)
        try writeLegacyFlatMeeting(named: "fine")

        let records = try MeetingLibraryIndex.scan(directory: directory, processingURL: nil)

        // "blocked" stays flat (its .m4a never moved into the pre-existing empty folder) and is
        // ignored by folder-based scan, while "fine" migrates and shows up as a proper meeting.
        XCTAssertTrue(fileManager.fileExists(atPath: directory.appendingPathComponent("blocked.m4a").path))
        XCTAssertTrue(fileManager.fileExists(atPath: directory.appendingPathComponent("fine", isDirectory: true).appendingPathComponent("recording.m4a").path))
        XCTAssertEqual(records.map(\.displayName), ["fine"])
    }
}
