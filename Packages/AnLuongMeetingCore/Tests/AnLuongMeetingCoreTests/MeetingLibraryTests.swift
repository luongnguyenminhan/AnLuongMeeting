import XCTest
@testable import AnLuongMeetingCore

final class MeetingLibraryTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("AnLuongCore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testScanDerivesReadyPartialAndProcessing() throws {
        let ready = directory.appendingPathComponent("ready.m4a")
        let partial = directory.appendingPathComponent("partial.m4a")
        let processing = directory.appendingPathComponent("processing.m4a")
        for url in [ready, partial, processing] { try Data([0, 1]).write(to: url) }
        try Data("transcript".utf8).write(to: directory.appendingPathComponent("ready.txt"))
        try Data("note".utf8).write(to: directory.appendingPathComponent("ready.meeting-notes.txt"))

        let records = try MeetingLibraryIndex.scan(directory: directory, processingURL: processing)
        XCTAssertEqual(records.first(where: { $0.displayName == "ready" })?.status, .ready)
        XCTAssertEqual(records.first(where: { $0.displayName == "partial" })?.status, .partial)
        XCTAssertEqual(records.first(where: { $0.displayName == "processing" })?.status, .processing)
    }

    func testScanPopulatesCorrectionsURLOnlyWhenSidecarExists() throws {
        let withCorrections = directory.appendingPathComponent("with-corrections.m4a")
        let withoutCorrections = directory.appendingPathComponent("without-corrections.m4a")
        for url in [withCorrections, withoutCorrections] { try Data([0, 1]).write(to: url) }
        try Data("[]".utf8).write(to: directory.appendingPathComponent("with-corrections.note-corrections.json"))

        let records = try MeetingLibraryIndex.scan(directory: directory, processingURL: nil)

        XCTAssertNotNil(records.first(where: { $0.displayName == "with-corrections" })?.correctionsURL)
        XCTAssertNil(records.first(where: { $0.displayName == "without-corrections" })?.correctionsURL)
    }

    func testFilterSearchAndStatus() {
        let now = Date()
        let records = [
            MeetingRecord(displayName: "Planning", recordingURL: directory.appendingPathComponent("a.m4a"), transcriptURL: nil, meetingNoteURL: nil, modifiedAt: now, duration: nil, status: .ready),
            MeetingRecord(displayName: "Retro", recordingURL: directory.appendingPathComponent("b.m4a"), transcriptURL: nil, meetingNoteURL: nil, modifiedAt: now, duration: nil, status: .partial)
        ]
        let result = MeetingLibraryIndex.filtered(records, searchText: "plan", filter: .ready)
        XCTAssertEqual(result.map(\.displayName), ["Planning"])
    }
}
