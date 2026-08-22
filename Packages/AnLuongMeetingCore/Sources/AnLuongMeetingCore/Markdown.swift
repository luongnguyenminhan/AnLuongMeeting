import Foundation

public enum MarkdownBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case unorderedList([String])
    case orderedList([String])
    case quote(String)
    case code(String)
    case divider
}

public enum Markdown {
    public static func parse(_ markdown: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraphLines: [String] = []
        var listItems: [String] = []
        var listKind: ListKind?
        var quoteLines: [String] = []
        var codeLines: [String] = []
        var inCodeFence = false

        func flushParagraph() {
            let text = paragraphLines.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { blocks.append(.paragraph(text)) }
            paragraphLines.removeAll(keepingCapacity: true)
        }

        func flushList() {
            guard !listItems.isEmpty, let kind = listKind else { return }
            blocks.append(kind == .unordered ? .unorderedList(listItems) : .orderedList(listItems))
            listItems.removeAll(keepingCapacity: true)
            listKind = nil
        }

        func flushQuote() {
            let text = quoteLines.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { blocks.append(.quote(text)) }
            quoteLines.removeAll(keepingCapacity: true)
        }

        func flushCode() {
            blocks.append(.code(codeLines.joined(separator: "\n").trimmingCharacters(in: .newlines)))
            codeLines.removeAll(keepingCapacity: true)
        }

        for rawLine in markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if line.hasPrefix("```") {
                if inCodeFence { flushCode() } else {
                    flushParagraph(); flushList(); flushQuote(); codeLines.removeAll(keepingCapacity: true)
                }
                inCodeFence.toggle()
                continue
            }
            if inCodeFence { codeLines.append(rawLine); continue }
            if line.isEmpty { flushParagraph(); flushList(); flushQuote(); continue }

            if let heading = heading(from: line) {
                flushParagraph(); flushList(); flushQuote()
                blocks.append(.heading(level: heading.level, text: heading.text))
                continue
            }
            if isDivider(line) {
                flushParagraph(); flushList(); flushQuote(); blocks.append(.divider); continue
            }
            if line.hasPrefix(">") {
                flushParagraph(); flushList()
                quoteLines.append(String(line.dropFirst()).trimmingCharacters(in: .whitespaces))
                continue
            }
            if let unordered = listItem(from: line, kind: .unordered) {
                flushParagraph(); flushQuote();
                if listKind != .unordered { flushList(); listKind = .unordered }
                listItems.append(unordered)
                continue
            }
            if let ordered = listItem(from: line, kind: .ordered) {
                flushParagraph(); flushQuote()
                if listKind != .ordered { flushList(); listKind = .ordered }
                listItems.append(ordered)
                continue
            }
            flushList(); flushQuote(); paragraphLines.append(line)
        }

        if inCodeFence { flushCode() }
        flushParagraph(); flushList(); flushQuote()
        return blocks
    }

    private enum ListKind { case unordered, ordered }

    private static func heading(from line: String) -> (level: Int, text: String)? {
        let prefix = line.prefix { $0 == "#" }
        guard !prefix.isEmpty, prefix.count <= 6 else { return nil }
        let text = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : (prefix.count, String(text))
    }

    private static func listItem(from line: String, kind: ListKind) -> String? {
        switch kind {
        case .unordered:
            guard line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") else { return nil }
            return String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        case .ordered:
            guard let dot = line.firstIndex(of: "."), dot > line.startIndex else { return nil }
            let number = line[..<dot]
            guard number.allSatisfy(\.isNumber), line.index(after: dot) < line.endIndex else { return nil }
            return String(line[line.index(after: dot)...]).trimmingCharacters(in: .whitespaces)
        }
    }

    private static func isDivider(_ line: String) -> Bool {
        let compact = line.replacingOccurrences(of: " ", with: "")
        return compact == "---" || compact == "***" || compact == "___"
    }
}
