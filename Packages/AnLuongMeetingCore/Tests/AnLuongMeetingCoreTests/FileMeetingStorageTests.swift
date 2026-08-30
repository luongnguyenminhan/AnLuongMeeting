import XCTest
@testable import AnLuongMeetingCore

final class FileMeetingStorageTests: XCTestCase {
    private var directory: URL!
    private let fileManager = FileManager.default

    override func setUpWithError() throws {
        directory = fileManager.temporaryDirectory.appendingPathComponent("AnLuongFileStorageTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fileManager.removeItem(at: directory)
    }

    private func makeMeeting(named name: String, corrections: Bool = false) throws {
        let folder = directory.appendingPathComponent(name, isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: folder.appendingPathComponent("recording.m4a"))
        try Data("transcript".utf8).write(to: folder.appendingPathComponent("transcript.txt"))
        try Data("note".utf8).write(to: folder.appendingPathComponent("notes.txt"))
        if corrections { try Data("[]".utf8).write(to: folder.appendingPathComponent("corrections.json")) }
    }

    func testRenameMovesTheWholeFolderAndUpdatesArtifactURLs() throws {
        try makeMeeting(named: "old", corrections: true)
        let storage = FileMeetingStorage(directory: directory)
        let meeting = try XCTUnwrap(try storage.scan(processingURL: nil).first { $0.displayName == "old" })

        try storage.rename(meeting, to: "new")

        let newFolder = directory.appendingPathComponent("new", isDirectory: true)
        XCTAssertTrue(fileManager.fileExists(atPath: newFolder.appendingPathComponent("recording.m4a").path))
        XCTAssertTrue(fileManager.fileExists(atPath: newFolder.appendingPathComponent("transcript.txt").path))
        XCTAssertTrue(fileManager.fileExists(atPath: newFolder.appendingPathComponent("notes.txt").path))
        XCTAssertTrue(fileManager.fileExists(atPath: newFolder.appendingPathComponent("corrections.json").path))
        XCTAssertFalse(fileManager.fileExists(atPath: directory.appendingPathComponent("old", isDirectory: true).path))

        let renamed = try XCTUnwrap(try storage.scan(processingURL: nil).first { $0.displayName == "new" })
        XCTAssertEqual(renamed.recordingURL.standardizedFileURL, newFolder.appendingPathComponent("recording.m4a").standardizedFileURL)
    }

    func testRenameToExistingFolderNameThrows() throws {
        try makeMeeting(named: "source")
        try makeMeeting(named: "target")
        let storage = FileMeetingStorage(directory: directory)
        let meeting = try XCTUnwrap(try storage.scan(processingURL: nil).first { $0.displayName == "source" })

        XCTAssertThrowsError(try storage.rename(meeting, to: "target")) { error in
            XCTAssertEqual(error as? MeetingLibraryError, .nameAlreadyExists("target"))
        }
        XCTAssertTrue(fileManager.fileExists(atPath: directory.appendingPathComponent("source", isDirectory: true).path))
    }

    func testDeleteRemovesTheWholeFolderIncludingCorrectionsAndLeavesOthersUntouched() throws {
        try makeMeeting(named: "gone", corrections: true)
        try makeMeeting(named: "keep")
        let storage = FileMeetingStorage(directory: directory)
        let meeting = try XCTUnwrap(try storage.scan(processingURL: nil).first { $0.displayName == "gone" })

        try storage.permanentlyDelete(meeting)

        XCTAssertFalse(fileManager.fileExists(atPath: directory.appendingPathComponent("gone", isDirectory: true).path))
        XCTAssertTrue(fileManager.fileExists(atPath: directory.appendingPathComponent("keep", isDirectory: true).path))
    }
}
