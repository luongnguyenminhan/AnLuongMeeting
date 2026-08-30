import Foundation

/// A confirmed memory entry (glossary term or participant) that can be highlighted inline
/// in a rendered note and tapped to show an explanation.
struct TermHighlight: Identifiable, Equatable {
    enum Kind: Equatable {
        case glossary(GlossaryEntry)
        case participant(Participant)
    }

    let id: String
    let displayText: String
    let kind: Kind
}

func termHighlights(glossary: [GlossaryEntry], participants: [Participant]) -> [TermHighlight] {
    let glossaryHighlights = glossary.filter(\.confirmed).map { entry in
        TermHighlight(id: entry.id, displayText: entry.term, kind: .glossary(entry))
    }
    let participantHighlights = participants.filter(\.confirmed).map { participant in
        TermHighlight(id: participant.id, displayText: participant.name, kind: .participant(participant))
    }
    return glossaryHighlights + participantHighlights
}

/// Wraps every occurrence of each highlight's `displayText` as a markdown link
/// (`anluong-term://<id>`) — the same trick `wrapCorrectionsAsLinks` uses for flagged
/// corrections. Meant to run on text that's already been passed through
/// `wrapCorrectionsAsLinks`; since a highlight's display text is a confirmed term and a
/// correction's wrongText is (by construction) a *mis*heard variant of one, the two rarely
/// collide, and this mirrors that function's own simple longest-first, no-double-wrap
/// approach rather than adding link-nesting detection for a case that doesn't come up.
func wrapTermsAsLinks(in text: String, terms: [TermHighlight]) -> String {
    var result = text
    let candidates = terms
        .filter { !$0.displayText.isEmpty }
        .filter { !$0.displayText.contains(where: { "[]()".contains($0) }) }
        .sorted { $0.displayText.count > $1.displayText.count }
    for term in candidates where result.contains(term.displayText) {
        let link = "[\(term.displayText)](anluong-term://\(term.id))"
        guard !result.contains(link) else { continue }
        result = result.replacingOccurrences(of: term.displayText, with: link)
    }
    return result
}
