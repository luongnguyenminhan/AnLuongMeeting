import XCTest
@testable import AnLuongMeeting

final class GeminiMemoryDraftParsingTests: XCTestCase {
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
        XCTAssertEqual(draft.corrections.first?.kind, .glossaryTerm)
        XCTAssertEqual(draft.identityMerges.first?.names, ["Le Tan", "Duy Tan", "Eric Nguyen"])
    }

    func testParseMemoryDraftSkipsCorrectionWithUnknownKind() {
        let json = Data("""
        {"glossary": [], "participants": [], "stylePreferences": [],
         "corrections": [{"wrongText": "X", "correctText": "Y", "alternatives": [], "kind": "unknown", "confidence": 0.5, "snippet": "s"}],
         "identityMerges": []}
        """.utf8)

        let draft = GeminiTranscriptionService.parseMemoryDraft(from: json)

        XCTAssertTrue(draft.corrections.isEmpty)
    }

    func testParseMemoryDraftMissingKeysDecodeToEmptyArrays() {
        let json = Data("""
        {"glossary": [], "participants": [], "stylePreferences": []}
        """.utf8)

        let draft = GeminiTranscriptionService.parseMemoryDraft(from: json)

        XCTAssertTrue(draft.corrections.isEmpty)
        XCTAssertTrue(draft.identityMerges.isEmpty)
    }
}
