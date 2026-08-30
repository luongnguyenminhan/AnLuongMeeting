import Foundation

struct NoteCorrectionStore: Sendable {
    private let fileURL: URL
    private let fileManager: FileManager

    init(directory: URL, fileManager: FileManager = .default) {
        self.fileURL = directory.appendingPathComponent("corrections.json")
        self.fileManager = fileManager
    }

    func load() -> [NoteCorrection] {
        guard let raw = fileManager.contents(atPath: fileURL.path) else { return [] }
        return (try? JSONDecoder().decode([NoteCorrection].self, from: raw)) ?? []
    }

    func save(_ corrections: [NoteCorrection]) throws {
        let data = try JSONEncoder().encode(corrections)
        try data.write(to: fileURL, options: .atomic)
    }
}

/// Wraps every occurrence of each `pending` correction's `wrongText` as a markdown link
/// (`anluong-correction://<id>`) so it renders as a tappable highlight inside an
/// `AttributedString(markdown:)`-rendered `Text`. Longest-first so a short wrongText that is
/// a substring of a longer one never clobbers the longer link. Skips a correction whose
/// wrongText itself contains markdown link syntax, and is idempotent (never re-wraps text
/// that is already wrapped for that correction).
func wrapCorrectionsAsLinks(in text: String, corrections: [NoteCorrection]) -> String {
    var result = text
    let pending = corrections
        .filter { $0.status == .pending && !$0.wrongText.isEmpty }
        .filter { !$0.wrongText.contains(where: { "[]()".contains($0) }) }
        .sorted { $0.wrongText.count > $1.wrongText.count }
    for correction in pending where result.contains(correction.wrongText) {
        let link = "[\(correction.wrongText)](anluong-correction://\(correction.id))"
        guard !result.contains(link) else { continue }
        result = result.replacingOccurrences(of: correction.wrongText, with: link)
    }
    return result
}

/// Replaces every occurrence of `correction.wrongText` in raw (un-highlighted) note text
/// with the user's chosen replacement.
func applyCorrection(_ correction: NoteCorrection, chosenText: String, in noteText: String) -> String {
    noteText.replacingOccurrences(of: correction.wrongText, with: chosenText)
}

/// Deterministically rewrites every known ASR mishearing in `text` to its canonical spelling,
/// straight from the confirmed glossary/participant aliases — run right after transcription so
/// a known term like "Celesta" becomes "Celesnity" in the transcript itself, rather than hoping
/// the note-generation LLM notices and applies the correction on its own.
///
/// A single left-to-right scan, trying the longest alias first at each position: doing this as
/// separate whole-text `replacingOccurrences` passes (longest alias first) looks equivalent but
/// isn't — once a longer alias has been substituted, a shorter *unrelated* alias can still match
/// a substring of the replacement text itself and corrupt it (e.g. alias "An" clobbering the
/// "An" inside an already-substituted "Trường An"). Scanning once and advancing past each match
/// avoids ever re-examining replaced text.
func applyGlossaryCorrections(_ text: String, pairs: [(alias: String, canonical: String)]) -> String {
    let sortedPairs = pairs.filter { !$0.alias.isEmpty }.sorted { $0.alias.count > $1.alias.count }
    guard !sortedPairs.isEmpty else { return text }

    var result = ""
    var index = text.startIndex
    scan: while index < text.endIndex {
        for pair in sortedPairs {
            if let range = text.range(of: pair.alias, range: index..<text.endIndex), range.lowerBound == index {
                result += pair.canonical
                index = range.upperBound
                continue scan
            }
        }
        result.append(text[index])
        index = text.index(after: index)
    }
    return result
}
