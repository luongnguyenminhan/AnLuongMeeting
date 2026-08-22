import Foundation
import AVFoundation

extension Notification.Name {
    static let anluongLibraryDidChange = Notification.Name("AnLuongLibraryDidChange")
}

enum MeetingStatus: String, CaseIterable, Identifiable {
    case ready
    case partial
    case processing

    var id: String { rawValue }
}

enum MeetingFilter: String, CaseIterable, Identifiable {
    case all
    case ready
    case partial
    case processing

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All"
        case .ready: return "Ready"
        case .partial: return "Partial"
        case .processing: return "Processing"
        }
    }
}

struct MeetingRecord: Identifiable, Hashable {
    let id: String
    let displayName: String
    let recordingURL: URL
    let transcriptURL: URL?
    let meetingNoteURL: URL?
    let modifiedAt: Date
    let duration: TimeInterval?
    let status: MeetingStatus

    var hasTranscript: Bool { transcriptURL != nil }
    var hasMeetingNote: Bool { meetingNoteURL != nil }

    init(
        displayName: String,
        recordingURL: URL,
        transcriptURL: URL?,
        meetingNoteURL: URL?,
        modifiedAt: Date,
        duration: TimeInterval?,
        status: MeetingStatus
    ) {
        self.id = recordingURL.standardizedFileURL.path
        self.displayName = displayName
        self.recordingURL = recordingURL
        self.transcriptURL = transcriptURL
        self.meetingNoteURL = meetingNoteURL
        self.modifiedAt = modifiedAt
        self.duration = duration
        self.status = status
    }
}

enum MeetingLibraryError: LocalizedError {
    case directoryReadFailed(URL, String)
    case invalidMeetingName
    case nameAlreadyExists(String)
    case unsafeTarget(URL)
    case renameFailed(String)
    case deleteFailed(String)

    var errorDescription: String? {
        switch self {
        case .directoryReadFailed(let directory, let message):
            return "Could not read Recordings at \(directory.path): \(message)"
        case .invalidMeetingName:
            return "Enter a meeting name without path separators or reserved names."
        case .nameAlreadyExists(let name):
            return "A meeting named \"\(name)\" already exists."
        case .unsafeTarget(let url):
            return "Refusing to modify a file outside the Recordings directory: \(url.lastPathComponent)"
        case .renameFailed(let message):
            return "Could not rename the meeting: \(message)"
        case .deleteFailed(let message):
            return "Could not permanently delete the meeting: \(message)"
        }
    }
}

struct MeetingLibraryIndex {
    private static let recordingExtension = "m4a"
    private static let transcriptSuffix = ".txt"
    private static let meetingNoteSuffix = ".meeting-notes.txt"

    static func scan(
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

    static func filtered(
        _ records: [MeetingRecord],
        searchText: String,
        filter: MeetingFilter
    ) -> [MeetingRecord] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return records
            .filter { record in
                let matchesSearch = query.isEmpty || record.displayName.localizedCaseInsensitiveContains(query)
                let matchesFilter: Bool
                switch filter {
                case .all:
                    matchesFilter = true
                case .ready:
                    matchesFilter = record.status == .ready
                case .partial:
                    matchesFilter = record.status == .partial
                case .processing:
                    matchesFilter = record.status == .processing
                }
                return matchesSearch && matchesFilter
            }
            .sorted(by: sortRecords)
    }

    private static func sortRecords(_ lhs: MeetingRecord, _ rhs: MeetingRecord) -> Bool {
        if lhs.modifiedAt != rhs.modifiedAt {
            return lhs.modifiedAt > rhs.modifiedAt
        }
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
