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

            let sourceFolder = meeting.recordingURL.deletingLastPathComponent()
            try validateDirectChild(sourceFolder)
            let destinationFolder = directory.appendingPathComponent(trimmedName, isDirectory: true)
            guard !fileManager.fileExists(atPath: destinationFolder.path) else {
                throw MeetingLibraryError.nameAlreadyExists(trimmedName)
            }

            do {
                try fileManager.moveItem(at: sourceFolder, to: destinationFolder)
            } catch {
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

        let folder = meeting.recordingURL.deletingLastPathComponent()
        do {
            try validateDirectChild(folder)
            try fileManager.removeItem(at: folder)
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

    private func validateDirectChild(_ url: URL) throws {
        let directoryPath = directory.standardizedFileURL.path
        guard url.standardizedFileURL.deletingLastPathComponent().path == directoryPath else {
            throw MeetingLibraryError.unsafeTarget(url)
        }
    }
}
