// Hallmark · component: markdown document reader · genre: editorial · tone: austere
// states: default · hover · focus · active · disabled · loading · error · success
// contrast: pass (native macOS surfaces)

import SwiftUI

struct MeetingDetailView: View {
    let meeting: MeetingRecord
    @ObservedObject var engine: RecordingEngine
    let onRename: () -> Void
    let onDelete: () -> Void
    @State private var selectedTab: DetailTab
    @State private var isActionsPopoverPresented = false
    @State private var corrections: [NoteCorrection] = []
    @State private var activeCorrection: NoteCorrection?
    @State private var correctionError: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(meeting: MeetingRecord, engine: RecordingEngine, onRename: @escaping () -> Void, onDelete: @escaping () -> Void) {
        self.meeting = meeting
        self.engine = engine
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
        .background(AnLuongPalette.readingSurface)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { loadCorrections() }
        .onChange(of: engine.lastMemoryRefreshToken) { _, _ in loadCorrections() }
        .onChange(of: meeting.id) { _, _ in
            selectedTab = meeting.meetingNoteURL != nil ? .meetingNote : .transcript
            loadCorrections()
        }
        .popover(item: $activeCorrection) { correction in
            CorrectionPickerView(
                correction: correction,
                onChoose: { chosenText in applyCorrectionChoice(correction, chosenText: chosenText) },
                onKeepOriginal: { applyCorrectionChoice(correction, chosenText: nil) }
            )
        }
        .alert(
            "Could not save correction",
            isPresented: Binding(get: { correctionError != nil }, set: { if !$0 { correctionError = nil } })
        ) {
            Button("OK") { correctionError = nil }
        } message: {
            Text(correctionError ?? "Please try again.")
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            VStack(alignment: .leading, spacing: 7) {
                Text("Meeting detail")
                    .font(AnLuongTypography.body(11).weight(.semibold))
                    .foregroundStyle(AnLuongPalette.ivory.opacity(0.55))
                Text(meeting.displayName)
                    .font(AnLuongTypography.display(31))
                    .foregroundStyle(AnLuongPalette.ivory)
                    .lineLimit(2)
                HStack(spacing: 8) {
                    Text(meeting.modifiedAt.formatted(date: .abbreviated, time: .shortened))
                    Text("·")
                    Text(durationText(meeting.duration))
                    Text("·")
                    Text(AnLuongStatusStyle.style(for: meeting.status).title)
                }
                .font(AnLuongTypography.body(11))
                .foregroundStyle(AnLuongPalette.ivory.opacity(0.62))
            }

            Spacer()

            Button {
                isActionsPopoverPresented.toggle()
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
                    .foregroundStyle(AnLuongPalette.ivory)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Actions for \(meeting.displayName)")
            .popover(isPresented: $isActionsPopoverPresented, arrowEdge: .trailing) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(MeetingDetailAction.allCases, id: \.self) { action in
                        if action == .rename || action == .delete {
                            Divider()
                        }
                        actionButton(action)
                    }
                }
                .buttonStyle(.plain)
                .labelStyle(.titleAndIcon)
                .font(AnLuongTypography.body(13).weight(.medium))
                .foregroundStyle(AnLuongPalette.ivory)
                .padding(10)
                .frame(width: 224, alignment: .leading)
                .background(AnLuongPalette.graphiteRaised)
            }
        }
        .padding(26)
        .background(AnLuongPalette.graphite)
    }

    @ViewBuilder
    private func actionButton(_ action: MeetingDetailAction) -> some View {
        if action == .delete {
            Button(role: .destructive) {
                perform(action)
            } label: {
                Label(action.title, systemImage: action.systemImage)
            }
        } else {
            Button {
                perform(action)
            } label: {
                Label(action.title, systemImage: action.systemImage)
            }
            .disabled(isActionDisabled(action))
        }
    }

    private func perform(_ action: MeetingDetailAction) {
        isActionsPopoverPresented = false
        switch action {
        case .regenerateTranscript:
            engine.regenerate(meeting: meeting, mode: .transcriptOnly)
        case .regenerateNote:
            engine.regenerate(meeting: meeting, mode: .noteOnly)
        case .regenerateBoth:
            engine.regenerate(meeting: meeting, mode: .both)
        case .rename:
            onRename()
        case .delete:
            onDelete()
        }
    }

    private func isActionDisabled(_ action: MeetingDetailAction) -> Bool {
        guard action.isRegeneration else { return false }
        let noAPIKey = engine.geminiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return engine.isTranscribing || noAPIKey || (action == .regenerateNote && meeting.transcriptURL == nil)
    }

    private var tabBar: some View {
        HStack(spacing: 22) {
            tabButton(.meetingNote, title: "Meeting note", icon: "doc.text")
            tabButton(.transcript, title: "Transcript", icon: "text.bubble")
            Spacer()
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 14)
        .background(AnLuongPalette.readingSurface)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(AnLuongPalette.graphite.opacity(0.12))
                .frame(height: 1)
        }
    }

    private func tabButton(_ tab: DetailTab, title: String, icon: String) -> some View {
        Button {
            withAnimation(reduceMotion ? nil : AnLuongMotion.gentle) {
                selectedTab = tab
            }
        } label: {
            VStack(spacing: 8) {
                Label(title, systemImage: icon)
                    .font(AnLuongTypography.body(12).weight(.semibold))
                    .foregroundStyle(selectedTab == tab ? AnLuongPalette.graphite : AnLuongPalette.mutedInk)
                Capsule()
                    .fill(selectedTab == tab ? AnLuongPalette.clay : .clear)
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
            if meeting.meetingNoteURL != nil {
                ReadOnlyArtifactView(
                    url: meeting.meetingNoteURL,
                    emptyTitle: "Meeting note unavailable",
                    emptyMessage: "A meeting note has not been generated for this recording.",
                    reduceMotion: reduceMotion,
                    rendersMarkdown: true,
                    corrections: corrections,
                    onCorrectionTap: { activeCorrection = $0 }
                )
            } else {
                AnLuongEmptyState(
                    title: "Meeting note unavailable",
                    message: meeting.transcriptURL != nil
                        ? "Generate a meeting note from the existing transcript."
                        : "Generate a transcript first, then a meeting note.",
                    icon: "doc.text",
                    actionTitle: meeting.transcriptURL != nil ? "Generate Note" : "Generate Both",
                    action: {
                        let mode: RegenerationMode = meeting.transcriptURL != nil ? .noteOnly : .both
                        engine.regenerate(meeting: meeting, mode: mode)
                    }
                )
                .background(AnLuongPalette.readingSurface)
            }
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
                AnLuongEmptyState(
                    title: "Transcript unavailable",
                    message: "A transcript has not been generated for this recording.",
                    icon: "text.bubble",
                    actionTitle: "Generate Transcript",
                    action: {
                        engine.regenerate(meeting: meeting, mode: .transcriptOnly)
                    }
                )
                .background(AnLuongPalette.readingSurface)
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

    private func loadCorrections() {
        guard let noteURL = meeting.meetingNoteURL else { corrections = []; return }
        corrections = NoteCorrectionStore(directory: noteURL.deletingLastPathComponent()).load()
    }

    private func applyCorrectionChoice(_ correction: NoteCorrection, chosenText: String?) {
        guard let noteURL = meeting.meetingNoteURL else { return }
        var updatedCorrection = correction
        do {
            if let chosenText {
                let rawNote = try String(contentsOf: noteURL, encoding: .utf8)
                let fixedNote = applyCorrection(updatedCorrection, chosenText: chosenText, in: rawNote)
                try Data(fixedNote.utf8).write(to: noteURL, options: .atomic)
                updatedCorrection.status = .accepted

                var memory = engine.memoryStore.load()
                switch updatedCorrection.kind {
                case .glossaryTerm:
                    if let index = memory.glossary.firstIndex(where: { $0.term == chosenText }),
                       !memory.glossary[index].aliases.contains(correction.wrongText) {
                        memory.glossary[index].aliases.append(correction.wrongText)
                    }
                case .participantName:
                    if let index = memory.participants.firstIndex(where: { $0.name == chosenText }),
                       !memory.participants[index].aliases.contains(correction.wrongText) {
                        memory.participants[index].aliases.append(correction.wrongText)
                    }
                }
                try engine.memoryStore.save(memory)
            } else {
                updatedCorrection.status = .keptOriginal
            }

            let store = NoteCorrectionStore(directory: noteURL.deletingLastPathComponent())
            var all = store.load()
            if let index = all.firstIndex(where: { $0.id == correction.id }) {
                all[index] = updatedCorrection
            }
            try store.save(all)
            corrections = all
        } catch {
            correctionError = error.localizedDescription
        }
    }

    private enum DetailTab: Hashable {
        case meetingNote
        case transcript
    }
}

enum MeetingDetailAction: CaseIterable, Equatable, Hashable {
    case regenerateTranscript
    case regenerateNote
    case regenerateBoth
    case rename
    case delete

    var title: String {
        switch self {
        case .regenerateTranscript: return "Regenerate Transcript"
        case .regenerateNote: return "Regenerate Note"
        case .regenerateBoth: return "Regenerate Both"
        case .rename: return "Rename"
        case .delete: return "Delete Permanently"
        }
    }

    var systemImage: String {
        switch self {
        case .regenerateTranscript: return "arrow.triangle.2.circlepath"
        case .regenerateNote: return "doc.text.magnifyingglass"
        case .regenerateBoth: return "arrow.2.squarepath"
        case .rename: return "pencil"
        case .delete: return "trash"
        }
    }

    var isRegeneration: Bool {
        switch self {
        case .regenerateTranscript, .regenerateNote, .regenerateBoth: return true
        case .rename, .delete: return false
        }
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
                        .font(AnLuongTypography.body(12).weight(.semibold))
                        .foregroundStyle(AnLuongPalette.mutedInk)
                    Spacer()
                    Text("\(sections.count) turns")
                        .font(AnLuongTypography.mono(10))
                        .foregroundStyle(AnLuongPalette.mutedInk.opacity(0.72))
                }
                .padding(.bottom, 5)

                ForEach(sections) { section in
                    accordionRow(section)
                }
            }
            .padding(26)
        }
        .scrollIndicators(.hidden)
        .background(AnLuongPalette.readingSurface)
        .onAppear {
            if expandedID == nil { expandedID = sections.first?.id }
        }
    }

    private func accordionRow(_ section: TranscriptSection) -> some View {
        let isExpanded = expandedID == section.id
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(reduceMotion ? nil : AnLuongMotion.standard) {
                    expandedID = isExpanded ? nil : section.id
                }
            } label: {
                HStack(spacing: 12) {
                    Circle()
                        .fill(isExpanded ? AnLuongPalette.clay : AnLuongPalette.mistBlue)
                        .frame(width: 9, height: 9)
                    Text(section.speaker)
                        .font(AnLuongTypography.body(13).weight(.semibold))
                        .foregroundStyle(AnLuongPalette.graphite)
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AnLuongPalette.mutedInk)
                }
                .padding(.horizontal, 15)
                .padding(.vertical, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isExpanded ? .isSelected : [])

            if isExpanded {
                Text(section.text)
                    .font(AnLuongTypography.body(14))
                    .foregroundStyle(AnLuongPalette.graphite.opacity(0.84))
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
                .stroke(isExpanded ? AnLuongPalette.graphite.opacity(0.2) : .clear, lineWidth: 1)
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
    let corrections: [NoteCorrection]
    let onCorrectionTap: ((NoteCorrection) -> Void)?

    init(
        url: URL?,
        emptyTitle: String,
        emptyMessage: String,
        reduceMotion: Bool,
        rendersMarkdown: Bool = false,
        corrections: [NoteCorrection] = [],
        onCorrectionTap: ((NoteCorrection) -> Void)? = nil
    ) {
        self.url = url
        self.text = nil
        self.emptyTitle = emptyTitle
        self.emptyMessage = emptyMessage
        self.reduceMotion = reduceMotion
        self.rendersMarkdown = rendersMarkdown
        self.corrections = corrections
        self.onCorrectionTap = onCorrectionTap
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
        self.corrections = []
        self.onCorrectionTap = nil
    }

    var body: some View {
        if let content = resolvedText {
            if rendersMarkdown {
                MarkdownDocumentView(markdown: content, reduceMotion: reduceMotion, corrections: corrections, onCorrectionTap: onCorrectionTap)
            } else {
                plainTextView(content)
            }
        } else {
            AnLuongEmptyState(
                title: emptyTitle,
                message: emptyMessage,
                icon: "doc.text"
            )
            .background(AnLuongPalette.readingSurface)
        }
    }

    private func plainTextView(_ content: String) -> some View {
        ScrollView {
            Text(content)
                .font(AnLuongTypography.body(15))
                .foregroundStyle(AnLuongPalette.graphite.opacity(0.88))
                .lineSpacing(5)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(28)
                .modifier(ArtifactReveal(reduceMotion: reduceMotion))
        }
        .scrollIndicators(.hidden)
        .background(AnLuongPalette.readingSurface)
    }

    private var resolvedText: String? {
        if let text { return text }
        guard let url else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}

enum AnLuongMarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case unorderedList([String])
    case orderedList([String])
    case quote(String)
    case code(String)
    case divider
}

enum AnLuongMarkdown {
    static func parse(_ markdown: String) -> [AnLuongMarkdownBlock] {
        var blocks: [AnLuongMarkdownBlock] = []
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
    var corrections: [NoteCorrection] = []
    var onCorrectionTap: ((NoteCorrection) -> Void)? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                documentMasthead

                LazyVStack(alignment: .leading, spacing: 17) {
                    ForEach(Array(AnLuongMarkdown.parse(markdown).enumerated()), id: \.offset) { _, block in
                        MarkdownBlockView(block: block, corrections: corrections)
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
        .background(AnLuongPalette.readingSurface)
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == "anluong-correction", let id = url.host,
                  let correction = corrections.first(where: { $0.id == id }) else { return .discarded }
            onCorrectionTap?(correction)
            return .handled
        })
    }

    private var documentMasthead: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("MEETING NOTE")
                .font(AnLuongTypography.mono(10).weight(.semibold))
                .tracking(1.5)
                .foregroundStyle(AnLuongPalette.mutedInk)
            Spacer()
            Text("MARKDOWN")
                .font(AnLuongTypography.mono(10))
                .tracking(1.2)
                .foregroundStyle(AnLuongPalette.mutedInk.opacity(0.58))
        }
        .padding(.bottom, 25)
    }
}

private struct MarkdownBlockView: View {
    let block: AnLuongMarkdownBlock
    var corrections: [NoteCorrection] = []

    var body: some View {
        switch block {
        case .heading(let level, let text):
            inlineText(text)
                .font(headingFont(for: level))
                .foregroundStyle(AnLuongPalette.graphite)
                .tracking(level == 1 ? -0.6 : -0.2)
                .padding(.top, level == 1 ? 8 : 4)
                .textSelection(.enabled)

        case .paragraph(let text):
            inlineText(text)
                .font(AnLuongTypography.body(15))
                .foregroundStyle(AnLuongPalette.graphite.opacity(0.86))
                .lineSpacing(5)
                .textSelection(.enabled)

        case .unorderedList(let items):
            list(items, ordered: false)

        case .orderedList(let items):
            list(items, ordered: true)

        case .quote(let text):
            HStack(alignment: .top, spacing: 14) {
                Rectangle()
                    .fill(AnLuongPalette.clay)
                    .frame(width: 3)
                inlineText(text)
                    .font(AnLuongTypography.body(15).italic())
                    .foregroundStyle(AnLuongPalette.mutedInk)
                    .lineSpacing(5)
                    .textSelection(.enabled)
            }
            .padding(.vertical, 4)

        case .code(let code):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code.isEmpty ? " " : code)
                    .font(AnLuongTypography.mono(12))
                    .foregroundStyle(AnLuongPalette.ivory.opacity(0.92))
                    .textSelection(.enabled)
                    .padding(16)
            }
            .background(AnLuongPalette.graphite, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

        case .divider:
            Rectangle()
                .fill(AnLuongPalette.graphite.opacity(0.15))
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
                        .font(AnLuongTypography.body(14).weight(.semibold))
                        .foregroundStyle(AnLuongPalette.mutedInk)
                        .frame(width: ordered ? 22 : 12, alignment: .leading)
                    inlineText(item)
                        .font(AnLuongTypography.body(15))
                        .foregroundStyle(AnLuongPalette.graphite.opacity(0.86))
                        .lineSpacing(4)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(.leading, 8)
    }

    private func inlineText(_ text: String) -> Text {
        let highlighted = wrapCorrectionsAsLinks(in: text, corrections: corrections)
        guard let attributed = try? AttributedString(markdown: highlighted) else {
            return Text(text)
        }
        return Text(attributed)
    }

    private func headingFont(for level: Int) -> Font {
        switch level {
        case 1:
            return AnLuongTypography.display(28)
        case 2:
            return AnLuongTypography.display(20)
        default:
            return AnLuongTypography.body(16).weight(.bold)
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

private struct CorrectionPickerView: View {
    let correction: NoteCorrection
    let onChoose: (String) -> Void
    let onKeepOriginal: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Did you mean…?").font(.headline)
            Text("\"\(correction.wrongText)\"").font(.subheadline).foregroundStyle(.secondary)
            Button(correction.correctText) { onChoose(correction.correctText); dismiss() }
                .buttonStyle(.borderedProminent)
            ForEach(correction.alternatives, id: \.self) { alternative in
                Button(alternative) { onChoose(alternative); dismiss() }
                    .buttonStyle(.bordered)
            }
            Button("Keep original") { onKeepOriginal(); dismiss() }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 260)
    }
}
