import Foundation

public protocol MeetingStorage {
    var recordingsDirectory: URL { get }
    func scan(processingURL: URL?) throws -> [MeetingRecord]
    func rename(_ meeting: MeetingRecord, to newDisplayName: String) throws
    func permanentlyDelete(_ meeting: MeetingRecord) throws
}

public struct FileMeetingStorage: MeetingStorage {
    public let recordingsDirectory: URL
    private let fileManager: FileManager

    public init(directory: URL, fileManager: FileManager = .default) {
        self.recordingsDirectory = directory.standardizedFileURL
        self.fileManager = fileManager
    }

    public func scan(processingURL: URL? = nil) throws -> [MeetingRecord] {
        try fileManager.createDirectory(
            at: recordingsDirectory,
            withIntermediateDirectories: true,
            attributes: nil
        )
        return try MeetingLibraryIndex.scan(
            directory: recordingsDirectory,
            processingURL: processingURL,
            fileManager: fileManager
        )
    }

    public func rename(_ meeting: MeetingRecord, to newDisplayName: String) throws {
        let name = try Self.validatedName(newDisplayName)
        guard name != meeting.displayName else { return }

        let sourceFolder = meeting.recordingURL.deletingLastPathComponent()
        try validateDirectChild(sourceFolder)
        let destinationFolder = recordingsDirectory.appendingPathComponent(name, isDirectory: true)

        guard !fileManager.fileExists(atPath: destinationFolder.path) else {
            throw MeetingLibraryError.nameAlreadyExists(name)
        }

        do {
            try fileManager.moveItem(at: sourceFolder, to: destinationFolder)
        } catch {
            throw MeetingLibraryError.renameFailed(error.localizedDescription)
        }
    }

    public func permanentlyDelete(_ meeting: MeetingRecord) throws {
        let folder = meeting.recordingURL.deletingLastPathComponent()
        do {
            try validateDirectChild(folder)
            try fileManager.removeItem(at: folder)
        } catch let error as MeetingLibraryError {
            throw error
        } catch {
            throw MeetingLibraryError.deleteFailed(error.localizedDescription)
        }
    }

    private func validateDirectChild(_ url: URL) throws {
        let directoryPath = recordingsDirectory.standardizedFileURL.path
        guard url.standardizedFileURL.deletingLastPathComponent().path == directoryPath else {
            throw MeetingLibraryError.unsafeTarget(url)
        }
    }

    private static func validatedName(_ value: String) throws -> String {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\\") else {
            throw MeetingLibraryError.invalidMeetingName
        }
        return name
    }
}
