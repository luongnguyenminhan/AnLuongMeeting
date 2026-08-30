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

    func testRequestBodyOmitsSystemInstructionWhenNilOrBlank() {
        let withNil = GeminiTranscriptionService.requestBody(parts: [["text": "hi"]], systemInstruction: nil)
        let withBlank = GeminiTranscriptionService.requestBody(parts: [["text": "hi"]], systemInstruction: "   ")

        XCTAssertNil(withNil["system_instruction"])
        XCTAssertNil(withBlank["system_instruction"])
    }

    func testRequestBodyIncludesSystemInstructionWhenPresent() {
        let body = GeminiTranscriptionService.requestBody(parts: [["text": "hi"]], systemInstruction: "glossary block")

        let systemInstruction = body["system_instruction"] as? [String: Any]
        let parts = systemInstruction?["parts"] as? [[String: Any]]
        XCTAssertEqual(parts?.first?["text"] as? String, "glossary block")
    }

    func testParseMemoryDraftDecodesAllThreeKinds() {
        let json = Data("""
        {
          "glossary": [{"term": "Zalo Pay", "category": "project", "confidence": 0.9, "snippet": "..."}],
          "participants": [{"name": "Chị Hoa", "confidence": 0.8, "snippet": "..."}],
          "stylePreferences": [{"note": "Luôn liệt kê rủi ro", "confidence": 0.7, "snippet": "..."}]
        }
        """.utf8)

        let draft = GeminiTranscriptionService.parseMemoryDraft(from: json)

        XCTAssertEqual(draft.glossary.first?.term, "Zalo Pay")
        XCTAssertEqual(draft.glossary.first?.category, .project)
        XCTAssertEqual(draft.glossary.first?.confirmed, false)
        XCTAssertEqual(draft.participants.first?.name, "Chị Hoa")
        XCTAssertEqual(draft.stylePreferences.first?.note, "Luôn liệt kê rủi ro")
    }

    func testParseMemoryDraftReturnsEmptyDraftOnMalformedJSON() {
        let draft = GeminiTranscriptionService.parseMemoryDraft(from: Data("not json".utf8))

        XCTAssertTrue(draft.glossary.isEmpty)
        XCTAssertTrue(draft.participants.isEmpty)
        XCTAssertTrue(draft.stylePreferences.isEmpty)
    }

    func testParseMemoryDraftSkipsEntryWithUnknownCategory() {
        let json = Data("""
        {"glossary": [{"term": "X", "category": "person", "confidence": 0.9, "snippet": "..."}], "participants": [], "stylePreferences": []}
        """.utf8)

        let draft = GeminiTranscriptionService.parseMemoryDraft(from: json)

        XCTAssertTrue(draft.glossary.isEmpty)
    }

    func testParseMemoryDraftDecodesCorrectionsAndIdentityMerges() {
        let json = Data("""
        {
          "glossary": [], "participants": [], "stylePreferences": [],
          "corrections": [{"wrongText": "Celesnet", "correctText": "Celesnity", "alternatives": ["Celestity"], "kind": "glossaryTerm", "confidence": 0.9, "snippet": "..."}],
          "identityMerges": [{"names": ["Le Tan", "Duy Tan", "Eric Nguyen"], "canonicalName": "Eric Nguyen", "confidence": 0.8, "snippet": "..."}]
        }
        """.utf8)

        let draft = GeminiTranscriptionService.parseMemoryDraft(from: json)

        XCTAssertEqual(draft.corrections.first?.wrongText, "Celesnet")
        XCTAssertEqual(draft.corrections.first?.correctText, "Celesnity")
        XCTAssertEqual(draft.corrections.first?.alternatives, ["Celestity"])
        XCTAssertEqual(draft.corrections.first?.kind, .glossaryTerm)
        XCTAssertEqual(draft.corrections.first?.status, .pending)
        XCTAssertEqual(draft.identityMerges.first?.names, ["Le Tan", "Duy Tan", "Eric Nguyen"])
        XCTAssertEqual(draft.identityMerges.first?.canonicalName, "Eric Nguyen")
    }

    func testParseMemoryDraftSkipsCorrectionWithUnknownKindOrMissingFields() {
        let json = Data("""
        {"glossary": [], "participants": [], "stylePreferences": [],
         "corrections": [
           {"wrongText": "X", "correctText": "Y", "alternatives": [], "kind": "unknown", "confidence": 0.5, "snippet": "s"},
           {"wrongText": "", "correctText": "Y", "alternatives": [], "kind": "glossaryTerm", "confidence": 0.5, "snippet": "s"}
         ],
         "identityMerges": [{"names": ["OnlyOne"], "confidence": 0.5, "snippet": "s"}]}
        """.utf8)

        let draft = GeminiTranscriptionService.parseMemoryDraft(from: json)

        XCTAssertTrue(draft.corrections.isEmpty)
        XCTAssertTrue(draft.identityMerges.isEmpty)
    }

    func testParseMemoryDraftMissingCorrectionsAndMergesKeysDecodeToEmptyArrays() {
        let json = Data("""
        {"glossary": [], "participants": [], "stylePreferences": []}
        """.utf8)

        let draft = GeminiTranscriptionService.parseMemoryDraft(from: json)

        XCTAssertTrue(draft.corrections.isEmpty)
        XCTAssertTrue(draft.identityMerges.isEmpty)
    }
}
