import Foundation

public enum MeetingStatus: String, CaseIterable, Identifiable, Sendable {
    case ready
    case partial
    case processing

    public var id: String { rawValue }
}

public enum MeetingFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case ready
    case partial
    case processing

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .all: return "All"
        case .ready: return "Ready"
        case .partial: return "Partial"
        case .processing: return "Processing"
        }
    }
}

public struct MeetingRecord: Identifiable, Hashable, Sendable {
    public let id: String
    public let displayName: String
    public let recordingURL: URL
    public let transcriptURL: URL?
    public let meetingNoteURL: URL?
    public let modifiedAt: Date
    public let duration: TimeInterval?
    public let status: MeetingStatus

    public var hasTranscript: Bool { transcriptURL != nil }
    public var hasMeetingNote: Bool { meetingNoteURL != nil }

    public init(
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

public enum MeetingLibraryError: LocalizedError, Equatable, Sendable {
    case directoryReadFailed(URL, String)
    case invalidMeetingName
    case nameAlreadyExists(String)
    case unsafeTarget(URL)
    case renameFailed(String)
    case deleteFailed(String)

    public var errorDescription: String? {
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
