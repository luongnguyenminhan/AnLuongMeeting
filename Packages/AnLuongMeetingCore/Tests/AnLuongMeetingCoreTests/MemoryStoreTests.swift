import XCTest
@testable import AnLuongMeetingCore

final class MemoryStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("AnLuongMemory-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testLoadReturnsEmptyDataWhenFileIsMissing() {
        let store = MemoryStore(directory: directory)
        XCTAssertEqual(store.load(), MemoryData())
    }

    func testLoadReturnsEmptyDataWhenFileIsCorrupt() throws {
        try Data("not json".utf8).write(to: directory.appendingPathComponent("memory.json"))
        let store = MemoryStore(directory: directory)
        XCTAssertEqual(store.load(), MemoryData())
    }

    func testSaveThenLoadRoundTripsAllFields() throws {
        let store = MemoryStore(directory: directory)
        var memory = MemoryData()
        memory.glossary = [
            GlossaryEntry(term: "Zalo Pay", category: .project, usageCount: 3, lastUsedAt: Date(timeIntervalSince1970: 1_700_000_000), source: .manual, confirmed: true)
        ]
        memory.participants = [
            Participant(name: "Chị Hoa", meetingCount: 2, lastSeenAt: Date(timeIntervalSince1970: 1_700_000_000), source: .suggested, confirmed: false, confidence: 0.8, snippet: "Chị Hoa nói...")
        ]
        memory.stylePreferences = [
            StylePreference(note: "Luôn liệt kê rủi ro", source: .manual, confirmed: true)
        ]
        memory.ignoredTerms = ["Zalô"]

        try store.save(memory)

        XCTAssertEqual(store.load(), memory)
    }

    func testRenderForPromptOrdersByUsageAndRecencyAndRespectsLimits() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var memory = MemoryData()
        memory.glossary = [
            GlossaryEntry(term: "Ít dùng", category: .jargon, usageCount: 1, lastUsedAt: now.addingTimeInterval(-30 * 86400), source: .manual, confirmed: true),
            GlossaryEntry(term: "Dùng nhiều", category: .jargon, usageCount: 20, lastUsedAt: now, source: .manual, confirmed: true),
            GlossaryEntry(term: "Chưa xác nhận", category: .jargon, usageCount: 100, lastUsedAt: now, source: .suggested, confirmed: false)
        ]

        let rendered = memory.renderForPrompt(glossaryLimit: 1, participantLimit: 1, styleLimit: 1, now: now)

        XCTAssertTrue(rendered.contains("Dùng nhiều"))
        XCTAssertFalse(rendered.contains("Ít dùng"))
        XCTAssertFalse(rendered.contains("Chưa xác nhận"))
    }

    func testRenderForPromptReturnsEmptyStringWhenNothingConfirmed() {
        var memory = MemoryData()
        memory.glossary = [GlossaryEntry(term: "X", category: .jargon, source: .suggested, confirmed: false)]

        XCTAssertEqual(memory.renderForPrompt(), "")
    }

    func testAcceptGlossaryConfirmsMatchingEntryOnly() {
        var memory = MemoryData()
        let target = GlossaryEntry(term: "X", category: .jargon, source: .suggested, confirmed: false)
        let other = GlossaryEntry(term: "Y", category: .jargon, source: .suggested, confirmed: false)
        memory.glossary = [target, other]

        memory.acceptGlossary(id: target.id)

        XCTAssertEqual(memory.glossary.first(where: { $0.id == target.id })?.confirmed, true)
        XCTAssertEqual(memory.glossary.first(where: { $0.id == other.id })?.confirmed, false)
    }

    func testRejectGlossaryRemovesEntryAndRemembersTerm() {
        var memory = MemoryData()
        let entry = GlossaryEntry(term: "X", category: .jargon, source: .suggested, confirmed: false)
        memory.glossary = [entry]

        memory.rejectGlossary(id: entry.id)

        XCTAssertTrue(memory.glossary.isEmpty)
        XCTAssertTrue(memory.ignoredTerms.contains("X"))
    }

    func testAcceptAndRejectParticipantAndStyleMirrorGlossaryBehavior() {
        var memory = MemoryData()
        let participant = Participant(name: "An", source: .suggested, confirmed: false)
        let style = StylePreference(note: "Note style", source: .suggested, confirmed: false)
        memory.participants = [participant]
        memory.stylePreferences = [style]

        memory.acceptParticipant(id: participant.id)
        memory.rejectStyle(id: style.id)

        XCTAssertEqual(memory.participants.first?.confirmed, true)
        XCTAssertTrue(memory.stylePreferences.isEmpty)
    }

    func testPendingCountCountsUnconfirmedRowsAcrossAllThreeLists() {
        var memory = MemoryData()
        memory.glossary = [GlossaryEntry(term: "X", category: .jargon, source: .suggested, confirmed: false)]
        memory.participants = [Participant(name: "An", source: .suggested, confirmed: false)]
        memory.stylePreferences = [StylePreference(note: "N", source: .manual, confirmed: true)]

        XCTAssertEqual(memory.pendingCount, 2)
    }

    func testMergeAppendsDraftEntriesAsUnconfirmed() {
        var memory = MemoryData()
        let draft = MemoryDraft(glossary: [GlossaryEntry(term: "Y", category: .jargon, source: .suggested, confirmed: false)])

        memory.merge(draft: draft)

        XCTAssertEqual(memory.glossary.count, 1)
        XCTAssertEqual(memory.pendingCount, 1)
    }

    func testMergeSkipsIgnoredAndAlreadyKnownTerms() {
        var memory = MemoryData()
        memory.ignoredTerms = ["ignored term"]
        memory.glossary = [GlossaryEntry(term: "Known Term", category: .jargon, source: .manual, confirmed: true)]
        let draft = MemoryDraft(glossary: [
            GlossaryEntry(term: "ignored term", category: .jargon, source: .suggested, confirmed: false),
            GlossaryEntry(term: "known term", category: .jargon, source: .suggested, confirmed: false),
            GlossaryEntry(term: "Fresh Term", category: .jargon, source: .suggested, confirmed: false)
        ])

        memory.merge(draft: draft)

        XCTAssertEqual(memory.glossary.map(\.term), ["Known Term", "Fresh Term"])
    }

    func testRenderForPromptIncludesAliasesInline() {
        var memory = MemoryData()
        memory.glossary = [
            GlossaryEntry(term: "Celesnity", category: .project, usageCount: 1, lastUsedAt: Date(), source: .manual, confirmed: true, aliases: ["Celesnet"])
        ]
        memory.participants = [
            Participant(name: "Eric Nguyen", meetingCount: 1, lastSeenAt: Date(), source: .manual, confirmed: true, aliases: ["Le Tan", "Duy Tan"])
        ]

        let rendered = memory.renderForPrompt()

        XCTAssertTrue(rendered.contains("Celesnity (also heard as: Celesnet)"))
        XCTAssertTrue(rendered.contains("Eric Nguyen (also called: Le Tan, Duy Tan)"))
    }

    func testRenderForPromptOmitsAliasParenthesesWhenNoAliases() {
        var memory = MemoryData()
        memory.glossary = [GlossaryEntry(term: "Celesnity", category: .project, source: .manual, confirmed: true)]

        let rendered = memory.renderForPrompt()

        XCTAssertTrue(rendered.contains("Celesnity"))
        XCTAssertFalse(rendered.contains("also heard as"))
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

    func testAcceptMergeReusesAnExistingParticipantInsteadOfDuplicating() {
        var memory = MemoryData()
        let existing = Participant(name: "Eric Nguyen", meetingCount: 5, source: .manual, confirmed: true)
        memory.participants = [existing]
        let suggestion = IdentityMergeSuggestion(names: ["Le Tan", "Eric Nguyen"], canonicalName: "Eric Nguyen")

        memory.acceptMerge(suggestion, canonicalName: "Eric Nguyen")

        XCTAssertEqual(memory.participants.count, 1)
        XCTAssertEqual(memory.participants.first?.meetingCount, 5)
        XCTAssertEqual(memory.participants.first?.aliases, ["Le Tan"])
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
        let store = NoteCorrectionStore(directory: directory, baseName: "Planning")
        XCTAssertTrue(store.load().isEmpty)
    }

    func testNoteCorrectionStoreSaveThenLoadRoundTrips() throws {
        let store = NoteCorrectionStore(directory: directory, baseName: "Planning")
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
}
