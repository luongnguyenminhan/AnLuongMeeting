import Foundation
import AVFoundation

public struct MeetingLibraryIndex {
    static let recordingFilename = "recording.m4a"
    static let transcriptFilename = "transcript.txt"
    static let meetingNoteFilename = "notes.txt"
    static let correctionsFilename = "corrections.json"

    public static func scan(
        directory: URL,
        processingURL: URL?,
        fileManager: FileManager = .default
    ) throws -> [MeetingRecord] {
        migrateLegacyLayoutIfNeeded(directory: directory, fileManager: fileManager)

        let urls: [URL]
        do {
            urls = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw MeetingLibraryError.directoryReadFailed(directory, error.localizedDescription)
        }

        let normalizedProcessingURL = processingURL?.standardizedFileURL
        return urls
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .compactMap { folderURL -> MeetingRecord? in
                let recordingURL = folderURL.appendingPathComponent(recordingFilename)
                guard fileManager.fileExists(atPath: recordingURL.path) else { return nil }

                let transcriptURL = folderURL.appendingPathComponent(transcriptFilename)
                let meetingNoteURL = folderURL.appendingPathComponent(meetingNoteFilename)
                let correctionsURL = folderURL.appendingPathComponent(correctionsFilename)
                let hasTranscript = fileManager.fileExists(atPath: transcriptURL.path)
                let hasMeetingNote = fileManager.fileExists(atPath: meetingNoteURL.path)
                let hasCorrections = fileManager.fileExists(atPath: correctionsURL.path)
                let modifiedAt = (try? recordingURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                    ?? Date.distantPast
                let status: MeetingStatus
                if normalizedProcessingURL == recordingURL.standardizedFileURL {
                    status = .processing
                } else if hasTranscript && hasMeetingNote {
                    status = .ready
                } else {
                    status = .partial
                }

                return MeetingRecord(
                    displayName: folderURL.lastPathComponent,
                    recordingURL: recordingURL,
                    transcriptURL: hasTranscript ? transcriptURL : nil,
                    meetingNoteURL: hasMeetingNote ? meetingNoteURL : nil,
                    correctionsURL: hasCorrections ? correctionsURL : nil,
                    modifiedAt: modifiedAt,
                    duration: duration(for: recordingURL),
                    status: status
                )
            }
            .sorted(by: sortRecords)
    }

    /// Converts every legacy `<name>.m4a` (and its same-prefixed siblings) found directly in
    /// `directory` into `<name>/{recording.m4a, transcript.txt, notes.txt, corrections.json}`.
    /// Per-meeting isolated: a failure moving one meeting's files rolls back only that meeting's
    /// moves and leaves it in flat form to retry on the next scan — it never touches another
    /// meeting or deletes data. Never overwrites an existing folder of the same name.
    static func migrateLegacyLayoutIfNeeded(directory: URL, fileManager: FileManager) {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }

        let legacyRecordings = urls.filter { $0.pathExtension.lowercased() == "m4a" }
        for recordingURL in legacyRecordings {
            let baseName = recordingURL.deletingPathExtension().lastPathComponent
            let folderURL = directory.appendingPathComponent(baseName, isDirectory: true)
            guard !fileManager.fileExists(atPath: folderURL.path) else { continue }

            do {
                try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: false)
            } catch {
                continue
            }

            var moved: [(source: URL, destination: URL)] = []
            do {
                let recordingDestination = folderURL.appendingPathComponent(recordingFilename)
                try fileManager.moveItem(at: recordingURL, to: recordingDestination)
                moved.append((recordingURL, recordingDestination))

                let siblingMoves: [(legacySuffix: String, newFilename: String)] = [
                    (".txt", transcriptFilename),
                    (".meeting-notes.txt", meetingNoteFilename),
                    (".note-corrections.json", correctionsFilename)
                ]
                for (legacySuffix, newFilename) in siblingMoves {
                    let source = directory.appendingPathComponent(baseName + legacySuffix)
                    guard fileManager.fileExists(atPath: source.path) else { continue }
                    let destination = folderURL.appendingPathComponent(newFilename)
                    try fileManager.moveItem(at: source, to: destination)
                    moved.append((source, destination))
                }
            } catch {
                for move in moved.reversed() {
                    try? fileManager.moveItem(at: move.destination, to: move.source)
                }
                try? fileManager.removeItem(at: folderURL)
            }
        }
    }

    public static func filtered(
        _ records: [MeetingRecord],
        searchText: String,
        filter: MeetingFilter
    ) -> [MeetingRecord] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return records.filter { record in
            let matchesSearch = query.isEmpty || record.displayName.localizedCaseInsensitiveContains(query)
            let matchesFilter: Bool
            switch filter {
            case .all: matchesFilter = true
            case .ready: matchesFilter = record.status == .ready
            case .partial: matchesFilter = record.status == .partial
            case .processing: matchesFilter = record.status == .processing
            }
            return matchesSearch && matchesFilter
        }.sorted(by: sortRecords)
    }

    private static func sortRecords(_ lhs: MeetingRecord, _ rhs: MeetingRecord) -> Bool {
        if lhs.modifiedAt != rhs.modifiedAt { return lhs.modifiedAt > rhs.modifiedAt }
        return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
    }

    private static func duration(for recordingURL: URL) -> TimeInterval? {
        guard let audioFile = try? AVAudioFile(forReading: recordingURL) else { return nil }
        let sampleRate = audioFile.fileFormat.sampleRate
        guard sampleRate.isFinite, sampleRate > 0 else { return nil }
        let seconds = Double(audioFile.length) / sampleRate
        return seconds.isFinite && seconds > 0 ? seconds : nil
    }
}
