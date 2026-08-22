import Foundation
import XCTest
@testable import AnLuongMeetingiOS
import AnLuongMeetingCore

final class IOSCoreBehaviorTests: XCTestCase {
    func testRecordingStateIsEquatable() {
        XCTAssertEqual(IOSRecordingState.recording, .recording)
        XCTAssertNotEqual(IOSRecordingState.recording, .idle)
    }

    func testInterruptionStateIsDistinctFromRecording() {
        XCTAssertNotEqual(IOSRecordingState.interrupted, .recording)
    }

    func testProcessingStateDistinguishesRegenerationModes() {
        XCTAssertEqual(
            IOSProcessingState.processing(mode: .noteOnly, current: 0, total: 0),
            .processing(mode: .noteOnly, current: 0, total: 0)
        )
    }

    func testFailedStateRetainsRetryableMessage() {
        XCTAssertEqual(IOSProcessingState.failed("network"), .failed("network"))
    }

    func testActionAvailabilityMatchesMeetingArtifactsAndConfiguration() {
        let fixture = MeetingRecord(
            displayName: "Partial meeting",
            recordingURL: URL(fileURLWithPath: "/tmp/partial.m4a"),
            transcriptURL: nil,
            meetingNoteURL: nil,
            modifiedAt: .now,
            duration: nil,
            status: .partial
        )

        XCTAssertFalse(IOSMeetingActionAvailability.isEnabled(.regenerateNote, meeting: fixture, apiKey: "valid", isBusy: false))
        for action in [IOSMeetingAction.regenerateTranscript, .regenerateNote, .regenerateBoth] {
            XCTAssertFalse(IOSMeetingActionAvailability.isEnabled(action, meeting: fixture, apiKey: "", isBusy: false))
        }
        XCTAssertTrue(IOSMeetingActionAvailability.isEnabled(.rename, meeting: fixture, apiKey: "", isBusy: true))
        XCTAssertTrue(IOSMeetingActionAvailability.isEnabled(.delete, meeting: fixture, apiKey: "", isBusy: true))
    }

    func testMeetingDetailPresentationUsesOneNativeTitle() {
        let meeting = MeetingRecord(
            displayName: "Planning",
            recordingURL: URL(fileURLWithPath: "/tmp/planning.m4a"),
            transcriptURL: nil,
            meetingNoteURL: nil,
            modifiedAt: .now,
            duration: nil,
            status: .partial
        )

        let presentation = IOSMeetingDetailPresentation(meeting: meeting, tab: .transcript)

        XCTAssertEqual(presentation.navigationTitle, "Planning")
        XCTAssertNil(presentation.contentTitle)
        XCTAssertEqual(presentation.artifactLabel, "Transcript")
    }

    func testProcessingStatusDoesNotRepeatAnErrorAsProgress() {
        XCTAssertFalse(IOSProcessingStatusPresentation.shouldShowProgressMessage("Add an API key", errorMessage: "Add an API key"))
        XCTAssertTrue(IOSProcessingStatusPresentation.shouldShowProgressMessage("Preparing…", errorMessage: nil))
    }

    @MainActor
    func testLibraryModelPublishesRecordingAndTranscriptFromStorage() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("library-fixture-\(UUID().uuidString)", isDirectory: true)
        let recordingURL = directory.appendingPathComponent("Planning.m4a")
        let transcriptURL = directory.appendingPathComponent("Planning.txt")
        let fixture = MeetingRecord(
            displayName: "Planning",
            recordingURL: recordingURL,
            transcriptURL: transcriptURL,
            meetingNoteURL: nil,
            modifiedAt: .now,
            duration: 42,
            status: .partial
        )
        let model = IOSLibraryViewModel(storage: TestMeetingStorage(records: [fixture]))

        model.reload()

        XCTAssertEqual(model.records, [fixture])
        XCTAssertEqual(model.records.first?.transcriptURL, transcriptURL)
    }

    @MainActor
    func testPendingWorkUsesInjectedProcessingDependencies() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("processing-fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let recordingURL = directory.appendingPathComponent("Planning.m4a")
        try Data([0]).write(to: recordingURL)
        let fixture = MeetingRecord(
            displayName: "Planning",
            recordingURL: recordingURL,
            transcriptURL: nil,
            meetingNoteURL: nil,
            modifiedAt: .now,
            duration: 1,
            status: .partial
        )
        let service = TestTranscriptionService()
        let notifications = TestNotificationSink()
        let coordinator = IOSPendingWorkCoordinator(
            storage: TestMeetingStorage(records: [fixture], recordingsDirectory: directory),
            keyStore: TestAPIKeyStore(value: "test-key"),
            notificationCoordinator: notifications,
            transcriptionService: service
        )

        await coordinator.resumePendingWork()
        for _ in 0..<3 { await Task.yield() }

        let transcribeCallCount = await service.callCount()
        XCTAssertEqual(transcribeCallCount, 1)
        XCTAssertEqual(coordinator.processingState, .completed(recordingURL))
        XCTAssertEqual(notifications.transcriptReadyCount, 1)
        XCTAssertEqual(notifications.meetingNoteReadyCount, 1)
        XCTAssertEqual(notifications.processingFailedCount, 0)
    }
}

private struct TestMeetingStorage: MeetingStorage {
    let records: [MeetingRecord]
    let recordingsDirectory: URL

    init(
        records: [MeetingRecord],
        recordingsDirectory: URL = URL(fileURLWithPath: "/tmp/ios-library-tests", isDirectory: true)
    ) {
        self.records = records
        self.recordingsDirectory = recordingsDirectory
    }

    func scan(processingURL: URL?) throws -> [MeetingRecord] { records }
    func rename(_ meeting: MeetingRecord, to newDisplayName: String) throws {}
    func permanentlyDelete(_ meeting: MeetingRecord) throws {}
}

private struct TestAPIKeyStore: APIKeyStore {
    let value: String?

    func load() -> String? { value }
    func save(_ value: String) throws {}
}

private actor TestTranscriptionService: MeetingTranscriptionService {
    private(set) var transcribeCallCount = 0

    func callCount() -> Int { transcribeCallCount }

    func transcribe(
        recordingURL: URL,
        apiKey: String,
        progress: @escaping @Sendable (TranscriptionProgress) -> Void
    ) async throws -> TranscriptionResult {
        transcribeCallCount += 1
        progress(TranscriptionProgress(stage: .segment, currentSegment: 1, totalSegments: 1, message: "Preparing the recording…"))
        progress(TranscriptionProgress(stage: .meetingNote, currentSegment: 1, totalSegments: 1, message: "Transcript saved. Generating the meeting note…"))
        progress(TranscriptionProgress(stage: .meetingNote, currentSegment: 1, totalSegments: 1, message: "Meeting note saved."))
        return TranscriptionResult(
            transcriptURL: recordingURL.deletingPathExtension().appendingPathExtension("txt"),
            meetingNoteURL: recordingURL.deletingPathExtension().appendingPathExtension("meeting-notes.txt")
        )
    }

    func transcribeOnly(
        recordingURL: URL,
        apiKey: String,
        progress: @escaping @Sendable (TranscriptionProgress) -> Void
    ) async throws -> URL {
        recordingURL.deletingPathExtension().appendingPathExtension("txt")
    }

    func regenerateNote(
        transcriptURL: URL,
        recordingURL: URL,
        apiKey: String,
        progress: @escaping @Sendable (TranscriptionProgress) -> Void
    ) async throws -> URL {
        recordingURL.deletingPathExtension().appendingPathExtension("meeting-notes.txt")
    }
}

@MainActor
private final class TestNotificationSink: IOSNotificationSink {
    private(set) var transcriptReadyCount = 0
    private(set) var meetingNoteReadyCount = 0
    private(set) var processingFailedCount = 0

    func notifyTranscriptReady() { transcriptReadyCount += 1 }
    func notifyMeetingNoteReady() { meetingNoteReadyCount += 1 }
    func notifyProcessingFailed() { processingFailedCount += 1 }
}
