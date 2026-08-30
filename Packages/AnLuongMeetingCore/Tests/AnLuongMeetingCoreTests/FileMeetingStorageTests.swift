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

    func testRenameMovesTheCorrectionsSidecarAlongsideOtherArtifacts() throws {
        for name in ["old.m4a", "old.txt", "old.meeting-notes.txt", "old.note-corrections.json"] {
            try Data(name.utf8).write(to: directory.appendingPathComponent(name))
        }
        let storage = FileMeetingStorage(directory: directory)
        let meeting = try XCTUnwrap(try storage.scan(processingURL: nil).first { $0.displayName == "old" })

        try storage.rename(meeting, to: "new")

        XCTAssertTrue(fileManager.fileExists(atPath: directory.appendingPathComponent("new.note-corrections.json").path))
        XCTAssertFalse(fileManager.fileExists(atPath: directory.appendingPathComponent("old.note-corrections.json").path))
    }

    func testDeleteRemovesTheCorrectionsSidecar() throws {
        for name in ["gone.m4a", "gone.note-corrections.json"] {
            try Data(name.utf8).write(to: directory.appendingPathComponent(name))
        }
        let storage = FileMeetingStorage(directory: directory)
        let meeting = try XCTUnwrap(try storage.scan(processingURL: nil).first { $0.displayName == "gone" })

        try storage.permanentlyDelete(meeting)

        XCTAssertFalse(fileManager.fileExists(atPath: directory.appendingPathComponent("gone.note-corrections.json").path))
    }
}
