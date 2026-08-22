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

    func testRenameUpdatesEveryExistingArtifactAndPreservesSuffixes() throws {
        makeMeeting(named: "old-name", transcript: true, note: true)
        let library = RecordingLibrary(directory: fixtureDirectory)
        library.refresh()
        let old = try XCTUnwrap(library.records.first { $0.displayName == "old-name" })

        try library.rename(old, to: "new-name")

        XCTAssertTrue(fileManager.fileExists(atPath: fixture("new-name.m4a").path))
        XCTAssertTrue(fileManager.fileExists(atPath: fixture("new-name.txt").path))
        XCTAssertTrue(fileManager.fileExists(atPath: fixture("new-name.meeting-notes.txt").path))
        XCTAssertFalse(fileManager.fileExists(atPath: fixture("old-name.m4a").path))
        XCTAssertEqual(library.records.first?.displayName, "new-name")
    }

    func testDeleteRemovesOnlyTheMeetingGroup() throws {
        makeMeeting(named: "to-delete", transcript: true, note: true)
        createFile(named: "keep.txt")
        let library = RecordingLibrary(directory: fixtureDirectory)
        library.refresh()
        let meeting = try XCTUnwrap(library.records.first { $0.displayName == "to-delete" })

        try library.deletePermanently(meeting)

        XCTAssertFalse(fileManager.fileExists(atPath: fixture("to-delete.m4a").path))
        XCTAssertFalse(fileManager.fileExists(atPath: fixture("to-delete.txt").path))
        XCTAssertFalse(fileManager.fileExists(atPath: fixture("to-delete.meeting-notes.txt").path))
        XCTAssertTrue(fileManager.fileExists(atPath: fixture("keep.txt").path))
    }

    func testRenameCollisionThrowsBeforeChangingAnyArtifact() throws {
        makeMeeting(named: "source", transcript: true, note: true)
        makeMeeting(named: "target", transcript: false, note: false)
        let library = RecordingLibrary(directory: fixtureDirectory)
        library.refresh()
        let source = try XCTUnwrap(library.records.first { $0.displayName == "source" })

        XCTAssertThrowsError(try library.rename(source, to: "target"))
        XCTAssertTrue(fileManager.fileExists(atPath: fixture("source.m4a").path))
        XCTAssertTrue(fileManager.fileExists(atPath: fixture("source.txt").path))
    }

    private func makeMeeting(named name: String, transcript: Bool, note: Bool) {
        createFile(named: "\(name).m4a")
        if transcript { createFile(named: "\(name).txt") }
        if note { createFile(named: "\(name).meeting-notes.txt") }
    }

    private func createFile(named name: String) {
        try! Data(name.utf8).write(to: fixture(name))
    }

    private func fixture(_ name: String) -> URL {
        fixtureDirectory.appendingPathComponent(name)
    }
}
