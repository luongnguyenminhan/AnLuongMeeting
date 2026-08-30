import XCTest
@testable import AnLuongMeeting

final class MemoryStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("AnLuongMacMemory-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testSaveThenLoadRoundTripsAliases() throws {
        let store = MemoryStore(directory: directory)
        let wholeSecond = Date(timeIntervalSince1970: 1_700_000_000)
        var memory = MemoryData()
        memory.glossary = [GlossaryEntry(term: "Celesnity", category: .project, lastUsedAt: wholeSecond, source: .manual, confirmed: true, aliases: ["Celesnet"])]
        memory.participants = [Participant(name: "Eric Nguyen", lastSeenAt: wholeSecond, source: .manual, confirmed: true, aliases: ["Le Tan", "Duy Tan"])]

        try store.save(memory)

        XCTAssertEqual(store.load(), memory)
    }

    func testRenderForPromptIncludesAliasesInline() {
        var memory = MemoryData()
        memory.glossary = [GlossaryEntry(term: "Celesnity", category: .project, usageCount: 1, lastUsedAt: Date(), source: .manual, confirmed: true, aliases: ["Celesnet"])]

        XCTAssertTrue(memory.renderForPrompt().contains("Celesnity (also heard as: Celesnet)"))
    }

    func testMergeParticipantsCombinesAliasesCountsAndRecency() {
        var memory = MemoryData()
        let older = Date(timeIntervalSince1970: 1_000)
        let newer = Date(timeIntervalSince1970: 2_000)
        let primary = Participant(name: "Eric Nguyen", meetingCount: 2, lastSeenAt: older, source: .manual, confirmed: true)
        let secondary = Participant(name: "Le Tan", meetingCount: 1, lastSeenAt: newer, source: .suggested, confirmed: false, aliases: ["Duy Tan"])
        memory.participants = [primary, secondary]

        memory.mergeParticipants(primaryID: primary.id, absorbing: secondary.id)

        XCTAssertEqual(memory.participants.count, 1)
        let merged = memory.participants[0]
        XCTAssertEqual(merged.name, "Eric Nguyen")
        XCTAssertEqual(merged.meetingCount, 3)
        XCTAssertEqual(merged.lastSeenAt, newer)
        XCTAssertEqual(Set(merged.aliases), Set(["Le Tan", "Duy Tan"]))
    }

    func testAcceptMergeCreatesMissingParticipantsAndMergesUnderCanonicalName() {
        var memory = MemoryData()
        let suggestion = IdentityMergeSuggestion(names: ["Le Tan", "Duy Tan", "Eric Nguyen"], canonicalName: "Eric Nguyen")
        memory.pendingMerges = [suggestion]

        memory.acceptMerge(suggestion, canonicalName: "Eric Nguyen")

        XCTAssertEqual(memory.participants.count, 1)
        XCTAssertEqual(memory.participants.first?.name, "Eric Nguyen")
        XCTAssertEqual(Set(memory.participants.first?.aliases ?? []), Set(["Le Tan", "Duy Tan"]))
        XCTAssertTrue(memory.pendingMerges.isEmpty)
    }

    func testRejectMergeRemovesSuggestionWithoutTouchingParticipants() {
        var memory = MemoryData()
        let suggestion = IdentityMergeSuggestion(names: ["A", "B"])
        memory.pendingMerges = [suggestion]

        memory.rejectMerge(suggestion)

        XCTAssertTrue(memory.pendingMerges.isEmpty)
        XCTAssertTrue(memory.participants.isEmpty)
    }

    func testNoteCorrectionStoreLoadReturnsEmptyWhenMissing() {
        let store = NoteCorrectionStore(directory: directory)
        XCTAssertTrue(store.load().isEmpty)
    }

    func testNoteCorrectionStoreSaveThenLoadRoundTrips() throws {
        let store = NoteCorrectionStore(directory: directory)
        let corrections = [
            NoteCorrection(wrongText: "Celesnet", correctText: "Celesnity", alternatives: ["Celestity"], kind: .glossaryTerm)
        ]

        try store.save(corrections)

        XCTAssertEqual(store.load(), corrections)
    }

    func testWrapCorrectionsAsLinksWrapsOnlyPendingCorrections() {
        let pending = NoteCorrection(wrongText: "Celesnet", correctText: "Celesnity", kind: .glossaryTerm, status: .pending)
        let accepted = NoteCorrection(wrongText: "FDE", correctText: "FE", kind: .glossaryTerm, status: .accepted)

        let result = wrapCorrectionsAsLinks(in: "Team Celesnet and FDE synced today.", corrections: [pending, accepted])

        XCTAssertEqual(result, "Team [Celesnet](anluong-correction://\(pending.id)) and FDE synced today.")
    }

    func testWrapCorrectionsAsLinksWrapsEveryOccurrence() {
        let correction = NoteCorrection(wrongText: "Celesnet", correctText: "Celesnity", kind: .glossaryTerm)

        let result = wrapCorrectionsAsLinks(in: "Celesnet met Celesnet again.", corrections: [correction])

        XCTAssertEqual(result, "[Celesnet](anluong-correction://\(correction.id)) met [Celesnet](anluong-correction://\(correction.id)) again.")
    }

    func testWrapCorrectionsAsLinksSkipsWrongTextContainingMarkdownSyntax() {
        let correction = NoteCorrection(wrongText: "[bad]", correctText: "Good", kind: .glossaryTerm)

        let result = wrapCorrectionsAsLinks(in: "This has [bad] in it.", corrections: [correction])

        XCTAssertEqual(result, "This has [bad] in it.")
    }

    func testApplyCorrectionReplacesEveryOccurrenceInNoteText() {
        let correction = NoteCorrection(wrongText: "Celesnet", correctText: "Celesnity", kind: .glossaryTerm)

        let result = applyCorrection(correction, chosenText: "Celesnity", in: "Celesnet met with Celesnet team.")

        XCTAssertEqual(result, "Celesnity met with Celesnity team.")
    }

    func testApplyGlossaryCorrectionsRewritesKnownMishearingsToCanonicalSpelling() {
        let pairs: [(alias: String, canonical: String)] = [(alias: "Celesta", canonical: "Celesnity")]

        let result = applyGlossaryCorrections("Đây là Celesta thì là công ty của An.", pairs: pairs)

        XCTAssertEqual(result, "Đây là Celesnity thì là công ty của An.")
    }

    func testApplyGlossaryCorrectionsAppliesLongestAliasFirst() {
        let pairs: [(alias: String, canonical: String)] = [
            (alias: "An", canonical: "AN-SHOULD-NOT-MATCH"),
            (alias: "Truong An", canonical: "Trường An")
        ]

        let result = applyGlossaryCorrections("Truong An is the candidate.", pairs: pairs)

        XCTAssertEqual(result, "Trường An is the candidate.")
    }

    func testGlossaryCorrectionPairsOnlyIncludesConfirmedEntriesWithAliases() {
        var memory = MemoryData()
        memory.glossary = [
            GlossaryEntry(term: "Celesnity", category: .project, source: .manual, confirmed: true, aliases: ["Celesta"]),
            GlossaryEntry(term: "Unconfirmed", category: .project, source: .suggested, confirmed: false, aliases: ["Unconf"])
        ]
        memory.participants = [
            Participant(name: "Trường An", source: .manual, confirmed: true, aliases: ["Truong An"])
        ]

        let pairs = memory.glossaryCorrectionPairs()

        XCTAssertEqual(pairs.count, 2)
        XCTAssertTrue(pairs.contains { $0.alias == "Celesta" && $0.canonical == "Celesnity" })
        XCTAssertTrue(pairs.contains { $0.alias == "Truong An" && $0.canonical == "Trường An" })
    }

    func testMergeGlossaryAsAliasMovesRejectedTermOntoTargetAndRemovesIt() {
        var memory = MemoryData()
        let target = GlossaryEntry(term: "Celesnity", category: .project, source: .manual, confirmed: true)
        let rejected = GlossaryEntry(term: "Celesta", category: .project, source: .suggested, confirmed: false)
        memory.glossary = [target, rejected]

        memory.mergeGlossaryAsAlias(id: rejected.id, intoTermID: target.id)

        XCTAssertEqual(memory.glossary.count, 1)
        XCTAssertEqual(memory.glossary.first?.aliases, ["Celesta"])
        XCTAssertTrue(memory.renderForPrompt().contains("Celesnity (also heard as: Celesta)"))
    }

    func testMergeParticipantAsAliasMovesRejectedNameOntoTargetAndRemovesIt() {
        var memory = MemoryData()
        let target = Participant(name: "Trường An", source: .manual, confirmed: true)
        let rejected = Participant(name: "Truong An", source: .suggested, confirmed: false)
        memory.participants = [target, rejected]

        memory.mergeParticipantAsAlias(id: rejected.id, intoParticipantID: target.id)

        XCTAssertEqual(memory.participants.count, 1)
        XCTAssertEqual(memory.participants.first?.aliases, ["Truong An"])
    }

    func testWrapTermsAsLinksWrapsConfirmedGlossaryAndParticipantMentions() {
        let entry = GlossaryEntry(term: "Celesnity", category: .project, source: .manual, confirmed: true)
        let participant = Participant(name: "Eric Nguyen", source: .manual, confirmed: true)
        let terms = termHighlights(glossary: [entry], participants: [participant])

        let result = wrapTermsAsLinks(in: "Celesnity met with Eric Nguyen today.", terms: terms)

        XCTAssertEqual(
            result,
            "[Celesnity](anluong-term://\(entry.id)) met with [Eric Nguyen](anluong-term://\(participant.id)) today."
        )
    }

    func testTermHighlightsExcludeUnconfirmedEntries() {
        let confirmed = GlossaryEntry(term: "Celesnity", category: .project, source: .manual, confirmed: true)
        let pending = GlossaryEntry(term: "Celesta", category: .project, source: .suggested, confirmed: false)

        let terms = termHighlights(glossary: [confirmed, pending], participants: [])

        XCTAssertEqual(terms.map(\.displayText), ["Celesnity"])
    }
}
