import Foundation

/// Runs one user instruction through a tool-calling loop against Gemini: the model can search
/// the note, search the transcript, read the glossary, flag a new term, and propose edits — the
/// same shape a coding agent works in — rather than answering in a single structured-JSON blob.
/// Nothing is written to disk here; `propose_edit` calls are only reported via `onPatch` for the
/// caller to render as a diff and apply once approved.
struct NoteEditAgent: Sendable {
    private let service: GeminiTranscriptionService
    private let memoryStore: MemoryStore
    private let transcriptURL: URL?

    init(service: GeminiTranscriptionService, memoryStore: MemoryStore, transcriptURL: URL?) {
        self.service = service
        self.memoryStore = memoryStore
        self.transcriptURL = transcriptURL
    }

    private static let maxRounds = 10

    private static let systemInstruction = """
    You are an editing assistant for a meeting note. You do not rewrite the whole note — you use \
    tools to research context, then call propose_edit for each small, targeted find/replace change \
    the user's instruction actually requires.

    Start by calling read_note whenever the instruction requires understanding the note as a \
    whole (e.g. "make it concise", "translate it", "reformat it") — do not try to pass a whole \
    paragraph as a search_note query, search_note is only for finding a specific known snippet. \
    Always confirm the exact text before proposing an edit — never guess at oldString; propose_edit \
    will tell you if it didn't match so you can retry with the corrected text. Call get_glossary \
    before translating or rewriting names/terms, so you use the confirmed spelling. If you \
    introduce a term or participant name that isn't in the glossary yet, call \
    suggest_glossary_term. Call finish with a short summary when you're done — if the instruction \
    needs no changes, call finish immediately without any propose_edit calls.
    """

    private static func toolDeclarations() -> [[String: Any]] {
        [[
            "functionDeclarations": [
                [
                    "name": "read_note",
                    "description": "Returns the full current note text verbatim. Call this first for any instruction that requires seeing the whole note (shortening, translating, reformatting) rather than a single known snippet.",
                    "parameters": ["type": "OBJECT", "properties": [String: Any]()]
                ],
                [
                    "name": "search_note",
                    "description": "Search the current note for a short substring; returns matching lines verbatim. Not for reading the whole note — use read_note for that.",
                    "parameters": ["type": "OBJECT", "properties": ["query": ["type": "STRING"]], "required": ["query"]]
                ],
                [
                    "name": "read_transcript",
                    "description": "Search the meeting transcript for a substring; returns matching lines verbatim. Omit query for a short preview from the start.",
                    "parameters": ["type": "OBJECT", "properties": ["query": ["type": "STRING"]]]
                ],
                [
                    "name": "get_glossary",
                    "description": "Returns confirmed glossary terms and participant names/aliases, for correct spelling and terminology.",
                    "parameters": ["type": "OBJECT", "properties": [String: Any]()]
                ],
                [
                    "name": "suggest_glossary_term",
                    "description": "Flags a new term or participant name encountered while editing that isn't in the glossary yet, for the user to confirm later.",
                    "parameters": [
                        "type": "OBJECT",
                        "properties": [
                            "term": ["type": "STRING"],
                            "category": ["type": "STRING", "enum": ["project", "jargon", "participant"]]
                        ],
                        "required": ["term", "category"]
                    ]
                ],
                [
                    "name": "propose_edit",
                    "description": "Proposes one targeted find/replace edit against the note. oldString must be copied verbatim from the note and unique; newString is the replacement (empty string to delete).",
                    "parameters": [
                        "type": "OBJECT",
                        "properties": [
                            "oldString": ["type": "STRING"],
                            "newString": ["type": "STRING"],
                            "explanation": ["type": "STRING"]
                        ],
                        "required": ["oldString", "newString", "explanation"]
                    ]
                ],
                [
                    "name": "finish",
                    "description": "Call this when you are done proposing edits for this instruction.",
                    "parameters": ["type": "OBJECT", "properties": ["summary": ["type": "STRING"]], "required": ["summary"]]
                ]
            ]
        ]]
    }

    func run(
        instruction: String,
        noteText: String,
        apiKey: String,
        onStatus: @escaping @Sendable (String) -> Void,
        onPatch: @escaping @Sendable (NoteEditPatch) -> Void
    ) async throws -> String {
        var contents: [[String: Any]] = [["role": "user", "parts": [["text": instruction]]]]
        var summary = "Reached the edit limit before finishing."

        for _ in 0..<Self.maxRounds {
            let (role, parts) = try await service.generateWithTools(
                contents: contents,
                tools: Self.toolDeclarations(),
                systemInstruction: Self.systemInstruction,
                apiKey: apiKey
            )
            contents.append(["role": role, "parts": parts])

            let calls = parts.compactMap { $0["functionCall"] as? [String: Any] }
            guard !calls.isEmpty else {
                if let text = parts.compactMap({ $0["text"] as? String }).first, !text.isEmpty {
                    summary = text
                }
                break
            }

            var responses: [[String: Any]] = []
            var didFinish = false
            for call in calls {
                guard let name = call["name"] as? String else { continue }
                let args = call["args"] as? [String: Any] ?? [:]
                let result = handle(name: name, args: args, noteText: noteText, onStatus: onStatus, onPatch: onPatch, summary: &summary, didFinish: &didFinish)
                responses.append(["functionResponse": ["name": name, "response": result]])
            }
            contents.append(["role": "function", "parts": responses])
            if didFinish { break }
        }
        return summary
    }

    private func handle(
        name: String,
        args: [String: Any],
        noteText: String,
        onStatus: @Sendable (String) -> Void,
        onPatch: @Sendable (NoteEditPatch) -> Void,
        summary: inout String,
        didFinish: inout Bool
    ) -> [String: Any] {
        switch name {
        case "read_note":
            onStatus("Reading the note…")
            return ["note": noteText]

        case "search_note":
            let query = (args["query"] as? String) ?? ""
            guard !query.isEmpty else {
                return ["error": "query is empty — use read_note to read the whole note instead."]
            }
            guard query.count <= 200 else {
                return ["error": "query is too long for a search — use read_note to read the whole note instead of searching for a large snippet."]
            }
            onStatus("Searching note for \"\(query)\"…")
            return ["matches": Self.searchLines(in: noteText, query: query)]

        case "read_transcript":
            let query = args["query"] as? String
            onStatus(query.map { "Searching transcript for \"\($0)\"…" } ?? "Reading transcript…")
            guard let transcriptURL, let transcript = try? String(contentsOf: transcriptURL, encoding: .utf8) else {
                return ["error": "No transcript is available for this meeting."]
            }
            if let query, !query.isEmpty {
                return ["matches": Self.searchLines(in: transcript, query: query)]
            }
            return ["preview": String(transcript.prefix(2000))]

        case "get_glossary":
            onStatus("Checking glossary…")
            return ["glossary": memoryStore.load().renderForPrompt()]

        case "suggest_glossary_term":
            guard let term = args["term"] as? String, !term.isEmpty else { return ["error": "Missing term."] }
            let category = (args["category"] as? String) ?? "jargon"
            onStatus("Noting new term \"\(term)\"…")
            var memory = memoryStore.load()
            if category == "participant" {
                if !memory.participants.contains(where: { $0.name == term }) {
                    memory.participants.append(Participant(name: term, source: .suggested, confirmed: false))
                }
            } else if !memory.glossary.contains(where: { $0.term == term }) {
                memory.glossary.append(GlossaryEntry(term: term, category: GlossaryCategory(rawValue: category) ?? .jargon, source: .suggested, confirmed: false))
            }
            try? memoryStore.save(memory)
            return ["status": "ok"]

        case "propose_edit":
            guard let oldString = args["oldString"] as? String, !oldString.isEmpty,
                  let newString = args["newString"] as? String else {
                return ["error": "Missing oldString/newString."]
            }
            guard noteText.contains(oldString) else {
                return ["error": "oldString not found in the current note text — re-check with search_note and retry with the exact text."]
            }
            let explanation = (args["explanation"] as? String) ?? ""
            onPatch(NoteEditPatch(oldString: oldString, newString: newString, explanation: explanation))
            onStatus("Proposed: \(explanation.isEmpty ? "an edit" : explanation)")
            return ["status": "ok"]

        case "finish":
            if let text = args["summary"] as? String, !text.isEmpty { summary = text }
            didFinish = true
            return ["status": "ok"]

        default:
            return ["error": "Unknown tool \"\(name)\"."]
        }
    }

    private static func searchLines(in text: String, query: String) -> [String] {
        guard !query.isEmpty else { return [] }
        var matches: [String] = []
        for line in text.components(separatedBy: "\n") {
            guard line.localizedCaseInsensitiveContains(query) else { continue }
            matches.append(line.trimmingCharacters(in: .whitespaces))
            if matches.count >= 10 { break }
        }
        return matches
    }
}
