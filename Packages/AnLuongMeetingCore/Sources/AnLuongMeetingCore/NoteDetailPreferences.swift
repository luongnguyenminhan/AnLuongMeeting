import Foundation

public enum NoteDetailLevel: String, Codable, CaseIterable, Sendable {
    case concise
    case detailed
}

/// User-configurable knobs that shape how detailed a generated meeting note is.
/// Persisted via UserDefaults, same pattern as other lightweight app preferences.
/// At the all-defaults value, `promptAddendum` is empty, so note generation is
/// byte-identical to the original fixed prompt.
public struct NoteDetailPreferences: Codable, Equatable, Sendable {
    public var level: NoteDetailLevel
    public var includeQuotes: Bool
    public var includeTechnicalDetails: Bool
    public var includeMinorPoints: Bool
    public var extraInstructions: String

    public init(
        level: NoteDetailLevel = .concise,
        includeQuotes: Bool = false,
        includeTechnicalDetails: Bool = false,
        includeMinorPoints: Bool = false,
        extraInstructions: String = ""
    ) {
        self.level = level
        self.includeQuotes = includeQuotes
        self.includeTechnicalDetails = includeTechnicalDetails
        self.includeMinorPoints = includeMinorPoints
        self.extraInstructions = extraInstructions
    }

    private static let defaultsKey = "anluong.noteDetailPreferences"

    public static func loadSaved(userDefaults: UserDefaults = .standard) -> Self {
        guard let data = userDefaults.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode(Self.self, from: data) else {
            return Self()
        }
        return decoded
    }

    public func save(userDefaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        userDefaults.set(data, forKey: Self.defaultsKey)
    }

    /// Extra instructions appended to the meeting-note prompt before the transcript.
    /// Empty when every preference is at its default, keeping the prompt unchanged.
    public var promptAddendum: String {
        let trimmedExtra = extraInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        var lines: [String] = []
        if level == .detailed {
            lines.append("- Viết chi tiết hơn mức bình thường: giữ lại nhiều thông tin cụ thể thay vì tóm tắt quá ngắn gọn.")
        }
        if includeQuotes {
            lines.append("- Trích dẫn nguyên văn các câu nói quan trọng khi phù hợp, có thể ghi rõ người nói.")
        }
        if includeTechnicalDetails {
            lines.append("- Giữ nguyên các con số, thông số kỹ thuật, tên giao thức/công cụ/thiết bị được nhắc đến chính xác như trong bản chép lời.")
        }
        if includeMinorPoints {
            lines.append("- Đừng bỏ qua các điểm phụ hoặc nhánh nhỏ của cuộc thảo luận; liệt kê cả những điểm ít quan trọng hơn.")
        }
        if !trimmedExtra.isEmpty {
            lines.append("- \(trimmedExtra)")
        }
        guard !lines.isEmpty else { return "" }
        return "\n\nYÊU CẦU BỔ SUNG VỀ ĐỘ CHI TIẾT:\n" + lines.joined(separator: "\n")
    }
}
