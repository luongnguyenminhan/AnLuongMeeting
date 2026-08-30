import Foundation

enum NoteDetailLevel: String, Codable, CaseIterable {
    case concise
    case detailed
}

/// User-configurable knobs that shape how detailed a generated meeting note is.
/// Persisted via UserDefaults, same pattern as other lightweight app preferences.
/// At the all-defaults value, `promptAddendum` is empty, so note generation is
/// byte-identical to the original fixed prompt.
struct NoteDetailPreferences: Codable, Equatable {
    var level: NoteDetailLevel = .concise
    var includeQuotes = false
    var includeTechnicalDetails = false
    var includeMinorPoints = false
    var extraInstructions = ""

    private static let defaultsKey = "anluong.noteDetailPreferences"

    static func loadSaved(userDefaults: UserDefaults = .standard) -> Self {
        guard let data = userDefaults.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode(Self.self, from: data) else {
            return Self()
        }
        return decoded
    }

    func save(userDefaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        userDefaults.set(data, forKey: Self.defaultsKey)
    }

    /// Extra instructions appended to the meeting-note prompt before the transcript.
    /// Empty when every preference is at its default, keeping the prompt unchanged.
    var promptAddendum: String {
        let trimmedExtra = extraInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        var lines: [String] = []
        if level == .detailed {
            lines.append("- Write in more detail than usual: keep specific information rather than summarizing too briefly.")
        }
        if includeQuotes {
            lines.append("- Quote important statements verbatim when appropriate, attributing the speaker if known.")
        }
        if includeTechnicalDetails {
            lines.append("- Keep numbers, technical specs, and protocol/tool/device names exactly as they appear in the transcript.")
        }
        if includeMinorPoints {
            lines.append("- Don't skip minor points or side branches of the discussion; include less important points too.")
        }
        if !trimmedExtra.isEmpty {
            lines.append("- \(trimmedExtra)")
        }
        guard !lines.isEmpty else { return "" }
        return "\n\nADDITIONAL USER REQUIREMENTS (MUST BE FOLLOWED STRICTLY, even if they differ from the instructions above, including regarding language):\n" + lines.joined(separator: "\n")
    }
}
