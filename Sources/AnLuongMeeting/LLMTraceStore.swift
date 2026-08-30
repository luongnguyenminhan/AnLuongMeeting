import Foundation

/// stage, prompt, response, succeeded — matches `LLMTraceRecorder.asTraceFunction()`.
typealias LLMTraceFunc = @Sendable (String, String, String, Bool) async -> Void
let noopTrace: LLMTraceFunc = { _, _, _, _ in }

/// One raw LLM call made while generating a transcript/note for a single meeting —
/// captured verbatim (no truncation) so it can be inspected later in the traceability
/// sidebar. `stage` is a short label like "decompose" or "explore[Kiến trúc hệ thống]".
struct LLMTraceEntry: Identifiable, Codable, Sendable, Equatable {
    let id: String
    var stage: String
    var prompt: String
    var response: String
    var succeeded: Bool
    var timestamp: Date

    init(
        id: String = UUID().uuidString,
        stage: String,
        prompt: String,
        response: String,
        succeeded: Bool,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.stage = stage
        self.prompt = prompt
        self.response = response
        self.succeeded = succeeded
        self.timestamp = timestamp
    }
}

/// Collects the raw prompt/response of every LLM call made during one generation run.
/// A fresh instance is created per run (per record/regenerate) and its contents are
/// persisted to that meeting's `trace.json` once the run finishes — a rerun replaces the
/// previous trace rather than accumulating stale entries from old runs.
actor LLMTraceRecorder {
    private(set) var entries: [LLMTraceEntry] = []

    func record(stage: String, prompt: String, response: String, succeeded: Bool = true) {
        entries.append(LLMTraceEntry(stage: stage, prompt: prompt, response: response, succeeded: succeeded))
    }

    /// A closure form suitable for passing across the `GeminiTranscriptionService` /
    /// `NoteResearchTree` call sites, which don't otherwise need to know this type exists.
    nonisolated func asTraceFunction() -> @Sendable (String, String, String, Bool) async -> Void {
        { [self] stage, prompt, response, succeeded in
            await self.record(stage: stage, prompt: prompt, response: response, succeeded: succeeded)
        }
    }
}

struct LLMTraceStore: Sendable {
    private let fileURL: URL
    private let fileManager: FileManager

    init(directory: URL, fileManager: FileManager = .default) {
        self.fileURL = directory.appendingPathComponent("trace.json")
        self.fileManager = fileManager
    }

    func load() -> [LLMTraceEntry] {
        guard let raw = fileManager.contents(atPath: fileURL.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([LLMTraceEntry].self, from: raw)) ?? []
    }

    func save(_ entries: [LLMTraceEntry]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(entries)
        try data.write(to: fileURL, options: .atomic)
    }
}
