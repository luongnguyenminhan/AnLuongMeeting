import Foundation
import AnLuongMeetingCore

struct IOSMeetingStorage: MeetingStorage {
    let recordingsDirectory: URL
    private let storage: FileMeetingStorage

    init(fileManager: FileManager = .default) {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        let directory = base.appendingPathComponent("Recordings", isDirectory: true)
        recordingsDirectory = directory
        storage = FileMeetingStorage(directory: directory, fileManager: fileManager)
    }

    func scan(processingURL: URL?) throws -> [MeetingRecord] {
        try storage.scan(processingURL: processingURL)
    }

    func rename(_ meeting: MeetingRecord, to newDisplayName: String) throws {
        try storage.rename(meeting, to: newDisplayName)
    }

    func permanentlyDelete(_ meeting: MeetingRecord) throws {
        try storage.permanentlyDelete(meeting)
    }
}
