import Foundation

enum MemorySource: String, Codable, Sendable {
    case manual
    case suggested
}

enum GlossaryCategory: String, Codable, Sendable {
    case project
    case jargon
}

struct GlossaryEntry: Identifiable, Codable, Sendable, Equatable {
    let id: String
    var term: String
    var category: GlossaryCategory
    var usageCount: Int
    var lastUsedAt: Date
    var source: MemorySource
    var confirmed: Bool
    var confidence: Double?
    var snippet: String?
    var aliases: [String]

    init(
        id: String = UUID().uuidString,
        term: String,
        category: GlossaryCategory,
        usageCount: Int = 0,
        lastUsedAt: Date = Date(),
        source: MemorySource,
        confirmed: Bool,
        confidence: Double? = nil,
        snippet: String? = nil,
        aliases: [String] = []
    ) {
        self.id = id
        self.term = term
        self.category = category
        self.usageCount = usageCount
        self.lastUsedAt = lastUsedAt
        self.source = source
        self.confirmed = confirmed
        self.confidence = confidence
        self.snippet = snippet
        self.aliases = aliases
    }
}

struct Participant: Identifiable, Codable, Sendable, Equatable {
    let id: String
    var name: String
    var meetingCount: Int
    var lastSeenAt: Date
    var source: MemorySource
    var confirmed: Bool
    var confidence: Double?
    var snippet: String?
    var aliases: [String]

    init(
        id: String = UUID().uuidString,
        name: String,
        meetingCount: Int = 0,
        lastSeenAt: Date = Date(),
        source: MemorySource,
        confirmed: Bool,
        confidence: Double? = nil,
        snippet: String? = nil,
        aliases: [String] = []
    ) {
        self.id = id
        self.name = name
        self.meetingCount = meetingCount
        self.lastSeenAt = lastSeenAt
        self.source = source
        self.confirmed = confirmed
        self.confidence = confidence
        self.snippet = snippet
        self.aliases = aliases
    }
}

struct StylePreference: Identifiable, Codable, Sendable, Equatable {
    let id: String
    var note: String
    var active: Bool
    var source: MemorySource
    var confirmed: Bool
    var confidence: Double?
    var snippet: String?

    init(
        id: String = UUID().uuidString,
        note: String,
        active: Bool = true,
        source: MemorySource,
        confirmed: Bool,
        confidence: Double? = nil,
        snippet: String? = nil
    ) {
        self.id = id
        self.note = note
        self.active = active
        self.source = source
        self.confirmed = confirmed
        self.confidence = confidence
        self.snippet = snippet
    }
}

struct MemoryData: Codable, Sendable, Equatable {
    var glossary: [GlossaryEntry]
    var participants: [Participant]
    var stylePreferences: [StylePreference]
    var ignoredTerms: Set<String>
    var pendingMerges: [IdentityMergeSuggestion]

    init(
        glossary: [GlossaryEntry] = [],
        participants: [Participant] = [],
        stylePreferences: [StylePreference] = [],
        ignoredTerms: Set<String> = [],
        pendingMerges: [IdentityMergeSuggestion] = []
    ) {
        self.glossary = glossary
        self.participants = participants
        self.stylePreferences = stylePreferences
        self.ignoredTerms = ignoredTerms
        self.pendingMerges = pendingMerges
    }
}

struct MemoryStore: Sendable {
    private let fileURL: URL
    private let fileManager: FileManager

    init(directory: URL, fileManager: FileManager = .default) {
        self.fileURL = directory.appendingPathComponent("memory.json")
        self.fileManager = fileManager
    }

    func load() -> MemoryData {
        guard let raw = fileManager.contents(atPath: fileURL.path) else { return MemoryData() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(MemoryData.self, from: raw)) ?? MemoryData()
    }

    func save(_ memory: MemoryData) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(memory)
        try data.write(to: fileURL, options: .atomic)
    }
}

enum CorrectionKind: String, Codable, Sendable {
    case glossaryTerm
    case participantName
}

enum CorrectionStatus: String, Codable, Sendable {
    case pending
    case accepted
    case rejected
    case keptOriginal
}

struct NoteCorrection: Identifiable, Codable, Sendable, Equatable {
    let id: String
    var wrongText: String
    var correctText: String
    var alternatives: [String]
    var kind: CorrectionKind
    var status: CorrectionStatus
    var confidence: Double?
    var snippet: String?

    init(
        id: String = UUID().uuidString,
        wrongText: String,
        correctText: String,
        alternatives: [String] = [],
        kind: CorrectionKind,
        status: CorrectionStatus = .pending,
        confidence: Double? = nil,
        snippet: String? = nil
    ) {
        self.id = id
        self.wrongText = wrongText
        self.correctText = correctText
        self.alternatives = alternatives
        self.kind = kind
        self.status = status
        self.confidence = confidence
        self.snippet = snippet
    }
}

struct IdentityMergeSuggestion: Identifiable, Codable, Sendable, Equatable {
    let id: String
    var names: [String]
    var canonicalName: String?
    var confidence: Double?
    var snippet: String?

    init(
        id: String = UUID().uuidString,
        names: [String],
        canonicalName: String? = nil,
        confidence: Double? = nil,
        snippet: String? = nil
    ) {
        self.id = id
        self.names = names
        self.canonicalName = canonicalName
        self.confidence = confidence
        self.snippet = snippet
    }
}

struct MemoryDraft: Sendable, Equatable {
    var glossary: [GlossaryEntry]
    var participants: [Participant]
    var stylePreferences: [StylePreference]
    var corrections: [NoteCorrection]
    var identityMerges: [IdentityMergeSuggestion]

    init(
        glossary: [GlossaryEntry] = [],
        participants: [Participant] = [],
        stylePreferences: [StylePreference] = [],
        corrections: [NoteCorrection] = [],
        identityMerges: [IdentityMergeSuggestion] = []
    ) {
        self.glossary = glossary
        self.participants = participants
        self.stylePreferences = stylePreferences
        self.corrections = corrections
        self.identityMerges = identityMerges
    }
}

extension MemoryData {
    var pendingCount: Int {
        glossary.filter { !$0.confirmed }.count
            + participants.filter { !$0.confirmed }.count
            + stylePreferences.filter { !$0.confirmed }.count
    }

    /// Considers only `confirmed == true` rows. Score = (usage + 1) / (1 + daysSinceLastUse),
    /// so frequently- and recently-used entries sort first; the render is capped so prompt
    /// size stays roughly constant regardless of how much history has accumulated.
    func renderForPrompt(
        glossaryLimit: Int = 150,
        participantLimit: Int = 50,
        styleLimit: Int = 20,
        now: Date = Date()
    ) -> String {
        let topParticipants = participants
            .filter(\.confirmed)
            .sorted { score(usage: $0.meetingCount, lastUsed: $0.lastSeenAt, now: now) > score(usage: $1.meetingCount, lastUsed: $1.lastSeenAt, now: now) }
            .prefix(participantLimit)
        let topGlossary = glossary
            .filter(\.confirmed)
            .sorted { score(usage: $0.usageCount, lastUsed: $0.lastUsedAt, now: now) > score(usage: $1.usageCount, lastUsed: $1.lastUsedAt, now: now) }
            .prefix(glossaryLimit)
        let topStyles = stylePreferences
            .filter { $0.confirmed && $0.active }
            .prefix(styleLimit)

        guard !topGlossary.isEmpty || !topParticipants.isEmpty || !topStyles.isEmpty else { return "" }

        var lines: [String] = []
        if !topParticipants.isEmpty {
            lines.append("Người tham gia thường gặp: " + topParticipants.map(participantLine).joined(separator: ", "))
        }
        if !topGlossary.isEmpty {
            lines.append("Thuật ngữ/tên riêng cần đánh vần chính xác: " + topGlossary.map(glossaryLine).joined(separator: ", "))
        }
        if !topStyles.isEmpty {
            lines.append("Ghi chú phong cách đã học: " + topStyles.map(\.note).joined(separator: "; "))
        }
        return lines.joined(separator: "\n")
    }

    /// Every confirmed glossary/participant alias paired with its canonical spelling —
    /// the raw material for `applyGlossaryCorrections`, which deterministically fixes known
    /// ASR mishearings in a transcript without relying on an LLM to notice and apply them.
    func glossaryCorrectionPairs() -> [(alias: String, canonical: String)] {
        let glossaryPairs = glossary.filter(\.confirmed).flatMap { entry in
            entry.aliases.map { (alias: $0, canonical: entry.term) }
        }
        let participantPairs = participants.filter(\.confirmed).flatMap { participant in
            participant.aliases.map { (alias: $0, canonical: participant.name) }
        }
        return glossaryPairs + participantPairs
    }

    private func glossaryLine(_ entry: GlossaryEntry) -> String {
        entry.aliases.isEmpty ? entry.term : "\(entry.term) (also heard as: \(entry.aliases.joined(separator: ", ")))"
    }

    private func participantLine(_ participant: Participant) -> String {
        participant.aliases.isEmpty ? participant.name : "\(participant.name) (also called: \(participant.aliases.joined(separator: ", ")))"
    }

    mutating func acceptGlossary(id: String) {
        guard let index = glossary.firstIndex(where: { $0.id == id }) else { return }
        glossary[index].confirmed = true
    }

    mutating func rejectGlossary(id: String) {
        guard let index = glossary.firstIndex(where: { $0.id == id }) else { return }
        ignoredTerms.insert(glossary[index].term)
        glossary.remove(at: index)
    }

    /// Instead of discarding a rejected suggestion as noise, records it as a known
    /// mishearing of an existing confirmed term — so `renderForPrompt` starts telling
    /// Gemini "also heard as: ..." for it going forward.
    mutating func mergeGlossaryAsAlias(id: String, intoTermID targetID: String) {
        guard let index = glossary.firstIndex(where: { $0.id == id }),
              let targetIndex = glossary.firstIndex(where: { $0.id == targetID }) else { return }
        let rejectedTerm = glossary[index].term
        if !glossary[targetIndex].aliases.contains(rejectedTerm) {
            glossary[targetIndex].aliases.append(rejectedTerm)
        }
        glossary.remove(at: index)
    }

    mutating func acceptParticipant(id: String) {
        guard let index = participants.firstIndex(where: { $0.id == id }) else { return }
        participants[index].confirmed = true
    }

    mutating func rejectParticipant(id: String) {
        guard let index = participants.firstIndex(where: { $0.id == id }) else { return }
        ignoredTerms.insert(participants[index].name)
        participants.remove(at: index)
    }

    /// See `mergeGlossaryAsAlias` — same idea for a mis-transcribed participant name.
    mutating func mergeParticipantAsAlias(id: String, intoParticipantID targetID: String) {
        guard let index = participants.firstIndex(where: { $0.id == id }),
              let targetIndex = participants.firstIndex(where: { $0.id == targetID }) else { return }
        let rejectedName = participants[index].name
        if !participants[targetIndex].aliases.contains(rejectedName) {
            participants[targetIndex].aliases.append(rejectedName)
        }
        participants.remove(at: index)
    }

    mutating func acceptStyle(id: String) {
        guard let index = stylePreferences.firstIndex(where: { $0.id == id }) else { return }
        stylePreferences[index].confirmed = true
    }

    mutating func rejectStyle(id: String) {
        stylePreferences.removeAll { $0.id == id }
    }

    mutating func merge(draft: MemoryDraft) {
        let existingGlossaryTerms = Set(glossary.map { $0.term.lowercased() })
        for entry in draft.glossary
        where !ignoredTerms.contains(entry.term) && !existingGlossaryTerms.contains(entry.term.lowercased()) {
            glossary.append(entry)
        }
        let existingNames = Set(participants.map { $0.name.lowercased() })
        for participant in draft.participants
        where !ignoredTerms.contains(participant.name) && !existingNames.contains(participant.name.lowercased()) {
            participants.append(participant)
        }
        let existingNotes = Set(stylePreferences.map { $0.note.lowercased() })
        for style in draft.stylePreferences where !existingNotes.contains(style.note.lowercased()) {
            stylePreferences.append(style)
        }
    }

    mutating func mergeParticipants(primaryID: String, absorbing secondaryID: String) {
        guard primaryID != secondaryID,
              let primaryIndex = participants.firstIndex(where: { $0.id == primaryID }),
              let secondary = participants.first(where: { $0.id == secondaryID }) else { return }
        var mergedAliases = Set(participants[primaryIndex].aliases)
        mergedAliases.insert(secondary.name)
        secondary.aliases.forEach { mergedAliases.insert($0) }
        mergedAliases.remove(participants[primaryIndex].name)
        participants[primaryIndex].aliases = Array(mergedAliases).sorted()
        participants[primaryIndex].meetingCount += secondary.meetingCount
        participants[primaryIndex].lastSeenAt = max(participants[primaryIndex].lastSeenAt, secondary.lastSeenAt)
        participants.removeAll { $0.id == secondaryID }
    }

    mutating func acceptMerge(_ suggestion: IdentityMergeSuggestion, canonicalName: String) {
        func findOrCreateParticipant(named name: String) -> String {
            if let existing = participants.first(where: {
                $0.name.caseInsensitiveCompare(name) == .orderedSame
                    || $0.aliases.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame })
            }) {
                return existing.id
            }
            let created = Participant(name: name, source: .suggested, confirmed: true)
            participants.append(created)
            return created.id
        }
        let primaryID = findOrCreateParticipant(named: canonicalName)
        for name in suggestion.names where name.caseInsensitiveCompare(canonicalName) != .orderedSame {
            let secondaryID = findOrCreateParticipant(named: name)
            if secondaryID != primaryID {
                mergeParticipants(primaryID: primaryID, absorbing: secondaryID)
            }
        }
        pendingMerges.removeAll { $0.id == suggestion.id }
    }

    mutating func rejectMerge(_ suggestion: IdentityMergeSuggestion) {
        pendingMerges.removeAll { $0.id == suggestion.id }
    }

    private func score(usage: Int, lastUsed: Date, now: Date) -> Double {
        let daysSinceUse = max(0, now.timeIntervalSince(lastUsed) / 86400)
        return Double(usage + 1) / (1 + daysSinceUse)
    }
}
