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

        let sources = artifactURLs(for: meeting)
        try validateDirectChildren(sources)
        let destinations = sources.map { destination(for: $0, name: name) }
        try validateDirectChildren(destinations)

        let sourcePaths = Set(sources.map { $0.standardizedFileURL.path })
        for destination in destinations where fileManager.fileExists(atPath: destination.path) {
            guard sourcePaths.contains(destination.standardizedFileURL.path) else {
                throw MeetingLibraryError.nameAlreadyExists(destination.deletingPathExtension().lastPathComponent)
            }
        }

        var moved: [(URL, URL)] = []
        do {
            for (source, destination) in zip(sources, destinations) {
                try fileManager.moveItem(at: source, to: destination)
                moved.append((source, destination))
            }
        } catch {
            for (source, destination) in moved.reversed() {
                try? fileManager.moveItem(at: destination, to: source)
            }
            throw MeetingLibraryError.renameFailed(error.localizedDescription)
        }
    }

    public func permanentlyDelete(_ meeting: MeetingRecord) throws {
        let targets = artifactURLs(for: meeting)
        do {
            try validateDirectChildren(targets)
            for target in targets where fileManager.fileExists(atPath: target.path) {
                try fileManager.removeItem(at: target)
            }
        } catch let error as MeetingLibraryError {
            throw error
        } catch {
            throw MeetingLibraryError.deleteFailed(error.localizedDescription)
        }
    }

    private func artifactURLs(for meeting: MeetingRecord) -> [URL] {
        [meeting.recordingURL, meeting.transcriptURL, meeting.meetingNoteURL, meeting.correctionsURL].compactMap { $0 }
    }

    private func destination(for source: URL, name: String) -> URL {
        let suffix: String
        if source.pathExtension.lowercased() == "m4a" {
            suffix = ".m4a"
        } else if source.lastPathComponent.hasSuffix(".meeting-notes.txt") {
            suffix = ".meeting-notes.txt"
        } else if source.lastPathComponent.hasSuffix(".note-corrections.json") {
            suffix = ".note-corrections.json"
        } else {
            suffix = ".txt"
        }
        return recordingsDirectory.appendingPathComponent(name + suffix)
    }

    private func validateDirectChildren(_ urls: [URL]) throws {
        let directoryPath = recordingsDirectory.standardizedFileURL.path
        for url in urls {
            guard url.standardizedFileURL.deletingLastPathComponent().path == directoryPath else {
                throw MeetingLibraryError.unsafeTarget(url)
            }
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
