import Foundation
import XCTest
@testable import AnLuongMeetingCore

final class GeminiRegenerationTests: XCTestCase {
    func testRegenerationModesExposeTheMacOSOrder() {
        XCTAssertEqual(
            GeminiRegenerationMode.allCases,
            [.transcriptOnly, .noteOnly, .both]
        )
    }

    func testNoteOnlyRequiresAnExistingTranscriptContract() async {
        let missingTranscript = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-transcript-\(UUID().uuidString).txt")
        let service = GeminiTranscriptionService()

        do {
            _ = try await service.regenerateNote(
                transcriptURL: missingTranscript,
                recordingURL: missingTranscript.deletingPathExtension().appendingPathExtension("m4a"),
                apiKey: "test-key"
            )
            XCTFail("Expected note-only regeneration to reject a missing transcript")
        } catch {
            XCTAssertEqual(error as? GeminiTranscriptionError, .emptyTranscript(0))
        }
    }
}
