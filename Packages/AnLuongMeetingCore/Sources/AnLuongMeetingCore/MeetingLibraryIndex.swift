import Foundation
import AVFoundation

public struct MeetingLibraryIndex {
    private static let recordingExtension = "m4a"
    private static let transcriptSuffix = ".txt"
    private static let meetingNoteSuffix = ".meeting-notes.txt"

    public static func scan(
        directory: URL,
        processingURL: URL?,
        fileManager: FileManager = .default
    ) throws -> [MeetingRecord] {
        let urls: [URL]
        do {
            urls = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw MeetingLibraryError.directoryReadFailed(directory, error.localizedDescription)
        }

        let normalizedProcessingURL = processingURL?.standardizedFileURL
        return urls
            .filter { $0.pathExtension.lowercased() == recordingExtension }
            .compactMap { recordingURL in
                let baseName = recordingURL.deletingPathExtension().lastPathComponent
                let transcriptURL = directory.appendingPathComponent(baseName + transcriptSuffix)
                let meetingNoteURL = directory.appendingPathComponent(baseName + meetingNoteSuffix)
                let hasTranscript = fileManager.fileExists(atPath: transcriptURL.path)
                let hasMeetingNote = fileManager.fileExists(atPath: meetingNoteURL.path)
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
                    displayName: baseName,
                    recordingURL: recordingURL,
                    transcriptURL: hasTranscript ? transcriptURL : nil,
                    meetingNoteURL: hasMeetingNote ? meetingNoteURL : nil,
                    modifiedAt: modifiedAt,
                    duration: duration(for: recordingURL),
                    status: status
                )
            }
            .sorted(by: sortRecords)
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
