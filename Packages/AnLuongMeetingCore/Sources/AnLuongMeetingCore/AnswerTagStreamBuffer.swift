import Foundation

/// Gates a stream of raw text deltas from the model so only the content between `<answer>` and
/// `</answer>` ever reaches the UI — everything before the opening tag (reasoning, self-correction,
/// a restated question) and everything after the closing tag is swallowed. Pure and network-free
/// so it's directly testable by feeding it fake deltas.
struct AnswerTagStreamBuffer {
    private var raw = ""
    private var emittedVisibleLength = 0
    private(set) var isDone = false

    private static let openTag = "<answer>"
    private static let closeTag = "</answer>"

    /// Feeds one more chunk of raw model output. Returns the new visible text to append to the
    /// UI, or an empty string if nothing new is visible yet (still buffering before the opening
    /// tag, already done, or holding back a tail that might be the start of the closing tag).
    mutating func append(_ delta: String) -> String {
        guard !isDone else { return "" }
        raw += delta

        guard let openRange = raw.range(of: Self.openTag) else { return "" }
        let afterOpen = raw[openRange.upperBound...]

        if let closeRange = afterOpen.range(of: Self.closeTag) {
            isDone = true
            return emit(upTo: afterOpen.distance(from: afterOpen.startIndex, to: closeRange.lowerBound), in: afterOpen)
        }

        // No closing tag yet — a chunk boundary could fall mid-tag (e.g. "...</ans" then "wer>"
        // in the next delta), so hold back any tail that could be the start of "</answer>" until
        // a later delta either completes or breaks that match.
        let holdback = Self.longestSuffixMatchingClosingTagPrefix(of: afterOpen)
        return emit(upTo: afterOpen.count - holdback, in: afterOpen)
    }

    /// Call once the stream ends. If the model never emitted an opening tag at all (some models
    /// skip it for a very short answer), falls back to the raw trimmed text instead of leaving
    /// the UI with nothing — mirrors `RecallAgent.extractAnswer`'s non-streaming fallback.
    mutating func finish() -> String {
        guard !isDone, !raw.contains(Self.openTag) else { return "" }
        isDone = true
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private mutating func emit(upTo visibleLength: Int, in text: Substring) -> String {
        guard visibleLength > emittedVisibleLength else { return "" }
        let newText = text.prefix(visibleLength).suffix(visibleLength - emittedVisibleLength)
        emittedVisibleLength = visibleLength
        return String(newText)
    }

    private static func longestSuffixMatchingClosingTagPrefix(of text: Substring) -> Int {
        let maxCheck = min(text.count, closeTag.count - 1)
        guard maxCheck > 0 else { return 0 }
        for length in stride(from: maxCheck, through: 1, by: -1) where text.suffix(length) == closeTag.prefix(length) {
            return length
        }
        return 0
    }
}
