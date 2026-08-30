import XCTest
@testable import AnLuongMeeting

@MainActor
final class RecordingLibraryTests: XCTestCase {
    private var fixtureDirectory: URL!
    private let fileManager = FileManager.default

    override func setUpWithError() throws {
        fixtureDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("AnLuongRecordingLibraryTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let fixtureDirectory {
            try? fileManager.removeItem(at: fixtureDirectory)
        }
    }

    func testRenameMovesTheWholeFolderAndUpdatesArtifactURLs() throws {
        makeMeeting(named: "old-name", transcript: true, note: true, corrections: true)
        let library = RecordingLibrary(directory: fixtureDirectory)
        library.refresh()
        let old = try XCTUnwrap(library.records.first { $0.displayName == "old-name" })

        try library.rename(old, to: "new-name")

        XCTAssertTrue(fileManager.fileExists(atPath: fixture("new-name/recording.m4a").path))
        XCTAssertTrue(fileManager.fileExists(atPath: fixture("new-name/transcript.txt").path))
        XCTAssertTrue(fileManager.fileExists(atPath: fixture("new-name/notes.txt").path))
        XCTAssertTrue(fileManager.fileExists(atPath: fixture("new-name/corrections.json").path))
        XCTAssertFalse(fileManager.fileExists(atPath: fixture("old-name").path))
        XCTAssertEqual(library.records.first?.displayName, "new-name")
    }

    func testDeleteRemovesTheWholeFolder() throws {
        makeMeeting(named: "to-delete", transcript: true, note: true, corrections: true)
        makeMeeting(named: "keep", transcript: false, note: false)
        let library = RecordingLibrary(directory: fixtureDirectory)
        library.refresh()
        let meeting = try XCTUnwrap(library.records.first { $0.displayName == "to-delete" })

        try library.deletePermanently(meeting)

        XCTAssertFalse(fileManager.fileExists(atPath: fixture("to-delete").path))
        XCTAssertTrue(fileManager.fileExists(atPath: fixture("keep").path))
    }

    func testRenameCollisionThrowsBeforeChangingAnyArtifact() throws {
        makeMeeting(named: "source", transcript: true, note: true)
        makeMeeting(named: "target", transcript: false, note: false)
        let library = RecordingLibrary(directory: fixtureDirectory)
        library.refresh()
        let source = try XCTUnwrap(library.records.first { $0.displayName == "source" })

        XCTAssertThrowsError(try library.rename(source, to: "target"))
        XCTAssertTrue(fileManager.fileExists(atPath: fixture("source/recording.m4a").path))
        XCTAssertTrue(fileManager.fileExists(atPath: fixture("source/transcript.txt").path))
    }

    private func makeMeeting(named name: String, transcript: Bool, note: Bool, corrections: Bool = false) {
        let folder = fixtureDirectory.appendingPathComponent(name, isDirectory: true)
        try! fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        try! Data("audio".utf8).write(to: folder.appendingPathComponent("recording.m4a"))
        if transcript { try! Data("transcript".utf8).write(to: folder.appendingPathComponent("transcript.txt")) }
        if note { try! Data("note".utf8).write(to: folder.appendingPathComponent("notes.txt")) }
        if corrections { try! Data("[]".utf8).write(to: folder.appendingPathComponent("corrections.json")) }
    }

    private func fixture(_ name: String) -> URL {
        fixtureDirectory.appendingPathComponent(name)
    }
}
