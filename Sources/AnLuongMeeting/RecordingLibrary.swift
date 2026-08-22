import Foundation
import Combine

@MainActor
final class RecordingLibrary: ObservableObject {
    @Published private(set) var records: [MeetingRecord] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isMutating = false
    @Published private(set) var errorMessage: String?

    let directory: URL
    private let fileManager: FileManager
    private var processingURL: URL?

    init(directory: URL, fileManager: FileManager = .default) {
        self.directory = directory.standardizedFileURL
        self.fileManager = fileManager
    }

    func refresh(processingURL: URL? = nil) {
        self.processingURL = processingURL
        isLoading = true
        defer { isLoading = false }

        do {
            records = try MeetingLibraryIndex.scan(
                directory: directory,
                processingURL: processingURL,
                fileManager: fileManager
            )
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func rename(_ meeting: MeetingRecord, to newDisplayName: String) throws {
        isMutating = true
        defer { isMutating = false }

        do {
            let trimmedName = try validatedName(newDisplayName)
            guard trimmedName != meeting.displayName else {
                refresh(processingURL: processingURL)
                return
            }

            let existingURLs = artifactURLs(for: meeting)
            try validateDirectChildren(existingURLs)

            let destinationURLs = destinationURLs(for: meeting, newDisplayName: trimmedName)
            try validateDirectChildren(destinationURLs)
            try validateDestinationsAreAvailable(destinationURLs, existingURLs: existingURLs)

            var completedMoves: [(source: URL, destination: URL)] = []
            do {
                for (source, destination) in zip(existingURLs, destinationURLs) {
                    try fileManager.moveItem(at: source, to: destination)
                    completedMoves.append((source: source, destination: destination))
                }
            } catch {
                for move in completedMoves.reversed() {
                    try? fileManager.moveItem(at: move.destination, to: move.source)
                }
                throw MeetingLibraryError.renameFailed(error.localizedDescription)
            }

            errorMessage = nil
            refresh(processingURL: processingURL)
        } catch {
            errorMessage = error.localizedDescription
            refresh(processingURL: processingURL)
            throw error
        }
    }

    func deletePermanently(_ meeting: MeetingRecord) throws {
        isMutating = true
        defer { isMutating = false }

        let targets = artifactURLs(for: meeting)
        do {
            try validateDirectChildren(targets)
            for target in targets where fileManager.fileExists(atPath: target.path) {
                try fileManager.removeItem(at: target)
            }
            errorMessage = nil
            refresh(processingURL: processingURL)
        } catch {
            let wrapped = error as? MeetingLibraryError
                ?? MeetingLibraryError.deleteFailed(error.localizedDescription)
            errorMessage = wrapped.localizedDescription
            refresh(processingURL: processingURL)
            throw wrapped
        }
    }

    private func validatedName(_ value: String) throws -> String {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              name != ".",
              name != "..",
              !name.contains("/"),
              !name.contains("\\") else {
            throw MeetingLibraryError.invalidMeetingName
        }
        return name
    }

    private func artifactURLs(for meeting: MeetingRecord) -> [URL] {
        [meeting.recordingURL, meeting.transcriptURL, meeting.meetingNoteURL].compactMap { $0 }
    }

    private func destinationURLs(for meeting: MeetingRecord, newDisplayName: String) -> [URL] {
        artifactURLs(for: meeting).map { source in
            let suffix: String
            if source.pathExtension.lowercased() == "m4a" {
                suffix = ".m4a"
            } else if source.lastPathComponent.hasSuffix(".meeting-notes.txt") {
                suffix = ".meeting-notes.txt"
            } else {
                suffix = ".txt"
            }
            return directory.appendingPathComponent(newDisplayName + suffix)
        }
    }

    private func validateDirectChildren(_ urls: [URL]) throws {
        let directoryPath = directory.standardizedFileURL.path
        for url in urls {
            let standardized = url.standardizedFileURL
            guard standardized.deletingLastPathComponent().path == directoryPath else {
                throw MeetingLibraryError.unsafeTarget(url)
            }
        }
    }

    private func validateDestinationsAreAvailable(
        _ destinations: [URL],
        existingURLs: [URL]
    ) throws {
        let existingPaths = Set(existingURLs.map { $0.standardizedFileURL.path })
        for destination in destinations where fileManager.fileExists(atPath: destination.path) {
            guard existingPaths.contains(destination.standardizedFileURL.path) else {
                throw MeetingLibraryError.nameAlreadyExists(destination.deletingPathExtension().lastPathComponent)
            }
        }
    }
}
