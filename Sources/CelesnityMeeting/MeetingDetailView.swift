// Hallmark · component: markdown document reader · genre: editorial · tone: austere
// states: default · hover · focus · active · disabled · loading · error · success
// contrast: pass (native macOS surfaces)

import SwiftUI

struct MeetingDetailView: View {
    let meeting: MeetingRecord
    let onRename: () -> Void
    let onDelete: () -> Void
    @State private var selectedTab: DetailTab
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(meeting: MeetingRecord, onRename: @escaping () -> Void, onDelete: @escaping () -> Void) {
        self.meeting = meeting
        self.onRename = onRename
        self.onDelete = onDelete
        _selectedTab = State(initialValue: meeting.meetingNoteURL != nil ? .meetingNote : .transcript)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            tabBar
            artifactContent
        }
        .background(CelesnityPalette.readingSurface)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: meeting.id) { _, _ in
            selectedTab = meeting.meetingNoteURL != nil ? .meetingNote : .transcript
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            VStack(alignment: .leading, spacing: 7) {
                Text("Meeting detail")
                    .font(CelesnityTypography.body(11).weight(.semibold))
                    .foregroundStyle(CelesnityPalette.ivory.opacity(0.55))
                Text(meeting.displayName)
                    .font(CelesnityTypography.display(31))
                    .foregroundStyle(CelesnityPalette.ivory)
                    .lineLimit(2)
                HStack(spacing: 8) {
                    Text(meeting.modifiedAt.formatted(date: .abbreviated, time: .shortened))
                    Text("·")
                    Text(durationText(meeting.duration))
                    Text("·")
                    Text(CelesnityStatusStyle.style(for: meeting.status).title)
                }
                .font(CelesnityTypography.body(11))
                .foregroundStyle(CelesnityPalette.ivory.opacity(0.62))
            }

            Spacer()

            Menu {
                Button("Rename", systemImage: "pencil", action: onRename)
                Divider()
                Button("Delete Permanently", systemImage: "trash", role: .destructive, action: onDelete)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
                    .foregroundStyle(CelesnityPalette.ivory)
                    .frame(width: 32, height: 32)
            }
            .menuStyle(.borderlessButton)
            .accessibilityLabel("Actions for \(meeting.displayName)")
        }
        .padding(26)
        .background(CelesnityPalette.graphite)
    }

    private var tabBar: some View {
        HStack(spacing: 22) {
            tabButton(.meetingNote, title: "Meeting note", icon: "doc.text")
            tabButton(.transcript, title: "Transcript", icon: "text.bubble")
            Spacer()
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 14)
        .background(CelesnityPalette.readingSurface)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(CelesnityPalette.graphite.opacity(0.12))
                .frame(height: 1)
        }
    }

    private func tabButton(_ tab: DetailTab, title: String, icon: String) -> some View {
        Button {
            withAnimation(reduceMotion ? nil : CelesnityMotion.gentle) {
                selectedTab = tab
            }
        } label: {
            VStack(spacing: 8) {
                Label(title, systemImage: icon)
                    .font(CelesnityTypography.body(12).weight(.semibold))
                    .foregroundStyle(selectedTab == tab ? CelesnityPalette.graphite : CelesnityPalette.mutedInk)
                Capsule()
                    .fill(selectedTab == tab ? CelesnityPalette.clay : .clear)
                    .frame(width: 34, height: 3)
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selectedTab == tab ? .isSelected : [])
    }

    @ViewBuilder
    private var artifactContent: some View {
        switch selectedTab {
        case .meetingNote:
            ReadOnlyArtifactView(
                url: meeting.meetingNoteURL,
                emptyTitle: "Meeting note unavailable",
                emptyMessage: "A meeting note has not been generated for this recording.",
                reduceMotion: reduceMotion,
                rendersMarkdown: true
            )
        case .transcript:
            if let transcriptURL = meeting.transcriptURL,
               let transcript = try? String(contentsOf: transcriptURL, encoding: .utf8) {
                let sections = transcriptSections(from: transcript)
                if sections.count > 1 {
                    TranscriptAccordionView(sections: sections, reduceMotion: reduceMotion)
                } else {
                    ReadOnlyArtifactView(
                        text: transcript,
                        emptyTitle: "Transcript unavailable",
                        emptyMessage: "A transcript has not been generated for this recording.",
                        reduceMotion: reduceMotion
                    )
                }
            } else {
                ReadOnlyArtifactView(
                    url: meeting.transcriptURL,
                    emptyTitle: "Transcript unavailable",
                    emptyMessage: "A transcript has not been generated for this recording.",
                    reduceMotion: reduceMotion
                )
            }
        }
    }

    private func durationText(_ duration: TimeInterval?) -> String {
        guard let duration, duration.isFinite, duration > 0 else { return "Duration unavailable" }
        let totalSeconds = Int(duration.rounded())
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }

    private func transcriptSections(from text: String) -> [TranscriptSection] {
        var sections: [TranscriptSection] = []
        var currentSpeaker = "Transcript"
        var currentLines: [String] = []

        func appendCurrent() {
            let content = currentLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { return }
            sections.append(TranscriptSection(id: sections.count, speaker: currentSpeaker, text: content))
            currentLines.removeAll(keepingCapacity: true)
        }

        for line in text.components(separatedBy: .newlines) {
            if line.hasPrefix("SPEAKER_") && line.hasSuffix(":") {
                appendCurrent()
                currentSpeaker = String(line.dropLast())
            } else {
                currentLines.append(line)
            }
        }
        appendCurrent()
        return sections
    }

    private enum DetailTab: Hashable {
        case meetingNote
        case transcript
    }
}

private struct TranscriptSection: Identifiable {
    let id: Int
    let speaker: String
    let text: String
}

private struct TranscriptAccordionView: View {
    let sections: [TranscriptSection]
    let reduceMotion: Bool
    @State private var expandedID: Int?

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                HStack {
                    Text("Speaker transcript")
                        .font(CelesnityTypography.body(12).weight(.semibold))
                        .foregroundStyle(CelesnityPalette.mutedInk)
                    Spacer()
                    Text("\(sections.count) turns")
                        .font(CelesnityTypography.mono(10))
                        .foregroundStyle(CelesnityPalette.mutedInk.opacity(0.72))
                }
                .padding(.bottom, 5)

                ForEach(sections) { section in
                    accordionRow(section)
                }
            }
            .padding(26)
        }
        .scrollIndicators(.hidden)
        .background(CelesnityPalette.readingSurface)
        .onAppear {
            if expandedID == nil { expandedID = sections.first?.id }
        }
    }

    private func accordionRow(_ section: TranscriptSection) -> some View {
        let isExpanded = expandedID == section.id
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(reduceMotion ? nil : CelesnityMotion.standard) {
                    expandedID = isExpanded ? nil : section.id
                }
            } label: {
                HStack(spacing: 12) {
                    Circle()
                        .fill(isExpanded ? CelesnityPalette.clay : CelesnityPalette.mistBlue)
                        .frame(width: 9, height: 9)
                    Text(section.speaker)
                        .font(CelesnityTypography.body(13).weight(.semibold))
                        .foregroundStyle(CelesnityPalette.graphite)
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(CelesnityPalette.mutedInk)
                }
                .padding(.horizontal, 15)
                .padding(.vertical, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isExpanded ? .isSelected : [])

            if isExpanded {
                Text(section.text)
                    .font(CelesnityTypography.body(14))
                    .foregroundStyle(CelesnityPalette.graphite.opacity(0.84))
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 15)
                    .padding(.bottom, 17)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(Color.white.opacity(0.48), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(isExpanded ? CelesnityPalette.graphite.opacity(0.2) : .clear, lineWidth: 1)
        }
    }
}

private struct ReadOnlyArtifactView: View {
    let url: URL?
    let text: String?
    let emptyTitle: String
    let emptyMessage: String
    let reduceMotion: Bool
    let rendersMarkdown: Bool

    init(
        url: URL?,
        emptyTitle: String,
        emptyMessage: String,
        reduceMotion: Bool,
        rendersMarkdown: Bool = false
    ) {
        self.url = url
        self.text = nil
        self.emptyTitle = emptyTitle
        self.emptyMessage = emptyMessage
        self.reduceMotion = reduceMotion
        self.rendersMarkdown = rendersMarkdown
    }

    init(
        text: String,
        emptyTitle: String,
        emptyMessage: String,
        reduceMotion: Bool,
        rendersMarkdown: Bool = false
    ) {
        self.url = nil
        self.text = text
        self.emptyTitle = emptyTitle
        self.emptyMessage = emptyMessage
        self.reduceMotion = reduceMotion
        self.rendersMarkdown = rendersMarkdown
    }

    var body: some View {
        if let content = resolvedText {
            if rendersMarkdown {
                MarkdownDocumentView(markdown: content, reduceMotion: reduceMotion)
            } else {
                plainTextView(content)
            }
        } else {
            CelesnityEmptyState(
                title: emptyTitle,
                message: emptyMessage,
                icon: "doc.text"
            )
            .background(CelesnityPalette.readingSurface)
        }
    }

    private func plainTextView(_ content: String) -> some View {
        ScrollView {
            Text(content)
                .font(CelesnityTypography.body(15))
                .foregroundStyle(CelesnityPalette.graphite.opacity(0.88))
                .lineSpacing(5)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(28)
                .modifier(ArtifactReveal(reduceMotion: reduceMotion))
        }
        .scrollIndicators(.hidden)
        .background(CelesnityPalette.readingSurface)
    }

    private var resolvedText: String? {
        if let text { return text }
        guard let url else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}

enum CelesnityMarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case unorderedList([String])
    case orderedList([String])
    case quote(String)
    case code(String)
    case divider
}

enum CelesnityMarkdown {
    static func parse(_ markdown: String) -> [CelesnityMarkdownBlock] {
        var blocks: [CelesnityMarkdownBlock] = []
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
            switch kind {
            case .unordered:
                blocks.append(.unorderedList(listItems))
            case .ordered:
                blocks.append(.orderedList(listItems))
            }
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
                if inCodeFence {
                    flushCode()
                } else {
                    flushParagraph()
                    flushList()
                    flushQuote()
                    codeLines.removeAll(keepingCapacity: true)
                }
                inCodeFence.toggle()
                continue
            }

            if inCodeFence {
                codeLines.append(rawLine)
                continue
            }

            if line.isEmpty {
                flushParagraph()
                flushList()
                flushQuote()
                continue
            }

            if let heading = heading(from: line) {
                flushParagraph()
                flushList()
                flushQuote()
                blocks.append(.heading(level: heading.level, text: heading.text))
                continue
            }

            if isDivider(line) {
                flushParagraph()
                flushList()
                flushQuote()
                blocks.append(.divider)
                continue
            }

            if let item = unorderedItem(from: line) {
                flushParagraph()
                flushQuote()
                if listKind != .unordered { flushList(); listKind = .unordered }
                listItems.append(item)
                continue
            }

            if let item = orderedItem(from: line) {
                flushParagraph()
                flushQuote()
                if listKind != .ordered { flushList(); listKind = .ordered }
                listItems.append(item)
                continue
            }

            if let quote = quote(from: line) {
                flushParagraph()
                flushList()
                quoteLines.append(quote)
                continue
            }

            if !listItems.isEmpty, rawLine.first?.isWhitespace == true {
                listItems[listItems.count - 1] += " " + line
            } else {
                flushList()
                flushQuote()
                paragraphLines.append(line)
            }
        }

        if inCodeFence { flushCode() }
        flushParagraph()
        flushList()
        flushQuote()
        return blocks
    }

    private enum ListKind: Equatable {
        case unordered
        case ordered
    }

    private static func heading(from line: String) -> (level: Int, text: String)? {
        let prefix = line.prefix { $0 == "#" }
        guard (1...6).contains(prefix.count), line.dropFirst(prefix.count).first == " " else { return nil }
        let text = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return (prefix.count, text)
    }

    private static func isDivider(_ line: String) -> Bool {
        let compact = line.replacingOccurrences(of: " ", with: "")
        return compact == "---" || compact == "***" || compact == "___"
    }

    private static func unorderedItem(from line: String) -> String? {
        for marker in ["- ", "* ", "• "] where line.hasPrefix(marker) {
            let item = String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
            return item.isEmpty ? nil : item
        }
        return nil
    }

    private static func orderedItem(from line: String) -> String? {
        let digits = line.prefix { $0.isNumber }
        guard !digits.isEmpty else { return nil }
        let remainder = line.dropFirst(digits.count)
        guard let marker = remainder.first, marker == "." || marker == ")",
              remainder.dropFirst().first == " " else { return nil }
        let item = remainder.dropFirst(2).trimmingCharacters(in: .whitespaces)
        return item.isEmpty ? nil : item
    }

    private static func quote(from line: String) -> String? {
        guard line.hasPrefix(">") else { return nil }
        return line.dropFirst().trimmingCharacters(in: .whitespaces)
    }
}

private struct MarkdownDocumentView: View {
    let markdown: String
    let reduceMotion: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                documentMasthead

                LazyVStack(alignment: .leading, spacing: 17) {
                    ForEach(Array(CelesnityMarkdown.parse(markdown).enumerated()), id: \.offset) { _, block in
                        MarkdownBlockView(block: block)
                    }
                }
                .frame(maxWidth: 760, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 52)
            .padding(.vertical, 34)
            .modifier(ArtifactReveal(reduceMotion: reduceMotion))
        }
        .scrollIndicators(.hidden)
        .background(CelesnityPalette.readingSurface)
    }

    private var documentMasthead: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("MEETING NOTE")
                .font(CelesnityTypography.mono(10).weight(.semibold))
                .tracking(1.5)
                .foregroundStyle(CelesnityPalette.mutedInk)
            Spacer()
            Text("MARKDOWN")
                .font(CelesnityTypography.mono(10))
                .tracking(1.2)
                .foregroundStyle(CelesnityPalette.mutedInk.opacity(0.58))
        }
        .padding(.bottom, 25)
    }
}

private struct MarkdownBlockView: View {
    let block: CelesnityMarkdownBlock

    var body: some View {
        switch block {
        case .heading(let level, let text):
            inlineText(text)
                .font(headingFont(for: level))
                .foregroundStyle(CelesnityPalette.graphite)
                .tracking(level == 1 ? -0.6 : -0.2)
                .padding(.top, level == 1 ? 8 : 4)
                .textSelection(.enabled)

        case .paragraph(let text):
            inlineText(text)
                .font(CelesnityTypography.body(15))
                .foregroundStyle(CelesnityPalette.graphite.opacity(0.86))
                .lineSpacing(5)
                .textSelection(.enabled)

        case .unorderedList(let items):
            list(items, ordered: false)

        case .orderedList(let items):
            list(items, ordered: true)

        case .quote(let text):
            HStack(alignment: .top, spacing: 14) {
                Rectangle()
                    .fill(CelesnityPalette.clay)
                    .frame(width: 3)
                inlineText(text)
                    .font(CelesnityTypography.body(15).italic())
                    .foregroundStyle(CelesnityPalette.mutedInk)
                    .lineSpacing(5)
                    .textSelection(.enabled)
            }
            .padding(.vertical, 4)

        case .code(let code):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code.isEmpty ? " " : code)
                    .font(CelesnityTypography.mono(12))
                    .foregroundStyle(CelesnityPalette.ivory.opacity(0.92))
                    .textSelection(.enabled)
                    .padding(16)
            }
            .background(CelesnityPalette.graphite, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

        case .divider:
            Rectangle()
                .fill(CelesnityPalette.graphite.opacity(0.15))
                .frame(height: 1)
                .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private func list(_ items: [String], ordered: Bool) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(ordered ? "\(index + 1)." : "•")
                        .font(CelesnityTypography.body(14).weight(.semibold))
                        .foregroundStyle(CelesnityPalette.mutedInk)
                        .frame(width: ordered ? 22 : 12, alignment: .leading)
                    inlineText(item)
                        .font(CelesnityTypography.body(15))
                        .foregroundStyle(CelesnityPalette.graphite.opacity(0.86))
                        .lineSpacing(4)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(.leading, 8)
    }

    private func inlineText(_ text: String) -> Text {
        guard let attributed = try? AttributedString(markdown: text) else {
            return Text(text)
        }
        return Text(attributed)
    }

    private func headingFont(for level: Int) -> Font {
        switch level {
        case 1:
            return CelesnityTypography.display(28)
        case 2:
            return CelesnityTypography.display(20)
        default:
            return CelesnityTypography.body(16).weight(.bold)
        }
    }
}

private struct ArtifactReveal: ViewModifier {
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        if reduceMotion {
            content
        } else {
            content.scrollTransition(.animated(.easeOut(duration: 0.24)), axis: .vertical) { view, phase in
                view
                    .opacity(phase.isIdentity ? 1 : 0.82)
                    .scaleEffect(phase.isIdentity ? 1 : 0.985)
            }
        }
    }
}
