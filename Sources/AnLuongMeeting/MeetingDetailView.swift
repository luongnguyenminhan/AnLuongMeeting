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
    @State private var correctionError: String?
    @State private var terms: [TermHighlight] = []
    @State private var trace: [LLMTraceEntry] = []
    @State private var isProcessingLogExpanded = false
    @State private var isReportingCorrection = false
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
            #if DEBUG
            processingLogSection
            #endif
            tabBar
            artifactContent
        }
        .background(AnLuongPalette.readingSurface)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { loadCorrections(); loadTrace() }
        .onChange(of: engine.lastMemoryRefreshToken) { _, _ in loadCorrections() }
        .onChange(of: engine.lastTraceRefreshToken) { _, _ in loadTrace() }
        .onChange(of: meeting.id) { _, _ in
            selectedTab = meeting.meetingNoteURL != nil ? .meetingNote : .transcript
            loadCorrections()
            loadTrace()
        }
        .alert(
            "Could not save correction",
            isPresented: Binding(get: { correctionError != nil }, set: { if !$0 { correctionError = nil } })
        ) {
            Button("OK") { correctionError = nil }
        } message: {
            Text(correctionError ?? "Please try again.")
        }
        .sheet(isPresented: $isReportingCorrection) {
            ReportCorrectionView(onSubmit: { wrongText, correctText, kind in
                reportCorrection(wrongText: wrongText, correctText: correctText, kind: kind)
            })
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

            if meeting.meetingNoteURL != nil {
                Button {
                    isReportingCorrection = true
                } label: {
                    Image(systemName: "text.badge.xmark")
                        .font(.title3)
                        .foregroundStyle(AnLuongPalette.ivory)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Report a wrong word in this note")
                .help("Report a word that isn't recognized or was mistranscribed")
            }

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
    private var processingLogSection: some View {
        let showsLiveLog = engine.progressLogRecordingURL == meeting.recordingURL && !engine.progressLog.isEmpty
        if showsLiveLog || !trace.isEmpty {
            let isActive = engine.isTranscribing && engine.processingRecordingURL == meeting.recordingURL
            DisclosureGroup(isExpanded: $isProcessingLogExpanded) {
                VStack(alignment: .leading, spacing: 0) {
                    if showsLiveLog {
                        ScrollViewReader { scrollProxy in
                            ScrollView {
                                VStack(alignment: .leading, spacing: 4) {
                                    ForEach(Array(engine.progressLog.enumerated()), id: \.offset) { index, line in
                                        Text(line)
                                            .font(AnLuongTypography.mono(11))
                                            .foregroundStyle(AnLuongPalette.ivory.opacity(0.8))
                                            .id(index)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, 8)
                            }
                            .frame(maxHeight: 160)
                            .onChange(of: engine.progressLog.count) { _, _ in
                                guard let lastIndex = engine.progressLog.indices.last else { return }
                                withAnimation(reduceMotion ? nil : AnLuongMotion.gentle) {
                                    scrollProxy.scrollTo(lastIndex, anchor: .bottom)
                                }
                            }
                        }
                    }
                    if !trace.isEmpty {
                        if showsLiveLog {
                            Divider().padding(.vertical, 8)
                            Text("RAW LLM INPUT/OUTPUT — \(trace.count) call\(trace.count == 1 ? "" : "s")")
                                .font(AnLuongTypography.mono(10).weight(.semibold))
                                .tracking(1.2)
                                .foregroundStyle(AnLuongPalette.ivory.opacity(0.6))
                                .padding(.bottom, 4)
                        }
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(trace) { entry in
                                    traceRow(entry)
                                    Divider().overlay(AnLuongPalette.ivory.opacity(0.12))
                                }
                            }
                        }
                        .frame(maxHeight: 420)
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    if isActive {
                        ProgressView().controlSize(.small)
                    }
                    Text("Processing Log")
                        .font(AnLuongTypography.body(12).weight(.semibold))
                        .foregroundStyle(AnLuongPalette.ivory)
                    Spacer()
                    Text(!trace.isEmpty
                        ? "\(trace.count) LLM call\(trace.count == 1 ? "" : "s")"
                        : "\(engine.progressLog.count) step\(engine.progressLog.count == 1 ? "" : "s")")
                        .font(AnLuongTypography.body(11))
                        .foregroundStyle(AnLuongPalette.ivory.opacity(0.6))
                }
            }
            .tint(AnLuongPalette.ivory)
            .padding(.horizontal, 26)
            .padding(.vertical, 10)
            .background(AnLuongPalette.graphiteRaised)
        }
    }

    /// One raw LLM call — stage, full prompt, full response, no truncation, selectable for
    /// copying while debugging why the note went wrong.
    private func traceRow(_ entry: LLMTraceEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(entry.stage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AnLuongPalette.ivory)
                if !entry.succeeded {
                    Text("FAILED")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.red)
                }
                Spacer()
                Text(entry.timestamp.formatted(date: .omitted, time: .standard))
                    .font(.caption2)
                    .foregroundStyle(AnLuongPalette.ivory.opacity(0.5))
            }
            Text("PROMPT").font(.caption2.weight(.semibold)).foregroundStyle(AnLuongPalette.ivory.opacity(0.5))
            Text(entry.prompt)
                .font(AnLuongTypography.mono(11))
                .foregroundStyle(AnLuongPalette.ivory.opacity(0.85))
                .textSelection(.enabled)
            Text("RESPONSE").font(.caption2.weight(.semibold)).foregroundStyle(AnLuongPalette.ivory.opacity(0.5))
            Text(entry.response)
                .font(AnLuongTypography.mono(11))
                .foregroundStyle(AnLuongPalette.ivory.opacity(0.85))
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 10)
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
                    onCorrectionResolved: { correction, chosenText in applyCorrectionChoice(correction, chosenText: chosenText) },
                    terms: terms,
                    onTermCorrectionSubmitted: { term, chosenText in applyTermCorrection(term, chosenText: chosenText) }
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
                    TranscriptConversationView(sections: sections, reduceMotion: reduceMotion)
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


    private func loadTrace() {
        let directory = (meeting.meetingNoteURL ?? meeting.transcriptURL ?? meeting.recordingURL).deletingLastPathComponent()
        trace = LLMTraceStore(directory: directory).load()
    }

    private func loadCorrections() {
        let memory = engine.memoryStore.load()
        terms = termHighlights(glossary: memory.glossary, participants: memory.participants)
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
                    if let index = memory.glossary.firstIndex(where: { $0.term == chosenText }) {
                        if !memory.glossary[index].aliases.contains(correction.wrongText) {
                            memory.glossary[index].aliases.append(correction.wrongText)
                        }
                    } else {
                        memory.glossary.append(GlossaryEntry(
                            term: chosenText, category: .project, source: .manual, confirmed: true,
                            aliases: [correction.wrongText]
                        ))
                    }
                case .participantName:
                    if let index = memory.participants.firstIndex(where: { $0.name == chosenText }) {
                        if !memory.participants[index].aliases.contains(correction.wrongText) {
                            memory.participants[index].aliases.append(correction.wrongText)
                        }
                    } else {
                        memory.participants.append(Participant(
                            name: chosenText, source: .manual, confirmed: true,
                            aliases: [correction.wrongText]
                        ))
                    }
                }
                try engine.memoryStore.save(memory)
                terms = termHighlights(glossary: memory.glossary, participants: memory.participants)
            } else {
                updatedCorrection.status = .keptOriginal
            }

            let store = NoteCorrectionStore(directory: noteURL.deletingLastPathComponent())
            var all = store.load()
            if let index = all.firstIndex(where: { $0.id == correction.id }) {
                all[index] = updatedCorrection
            } else {
                all.append(updatedCorrection)
            }
            try store.save(all)
            corrections = all
        } catch {
            correctionError = error.localizedDescription
        }
    }

    /// Lets a user dispute a highlighted term/name directly from its explain popup — not just
    /// pre-flagged ASR corrections. Reuses `applyCorrectionChoice` so the fix is applied to the
    /// note text and promoted into memory the same way an accepted flagged correction is,
    /// which is exactly the "store it to improve accuracy later" behavior for a manual fix too.
    private func applyTermCorrection(_ term: TermHighlight, chosenText: String) {
        let trimmed = chosenText.trimmingCharacters(in: .whitespacesAndNewlines)
        let wrongText: String
        let kind: CorrectionKind
        switch term.kind {
        case .glossary(let entry): wrongText = entry.term; kind = .glossaryTerm
        case .participant(let participant): wrongText = participant.name; kind = .participantName
        }
        guard !trimmed.isEmpty, trimmed != wrongText else { return }
        applyCorrectionChoice(NoteCorrection(wrongText: wrongText, correctText: trimmed, kind: kind), chosenText: trimmed)
    }

    /// Handles a word the user typed in manually via "Report a wrong word…" — for text that
    /// isn't recognized as a term/name at all (so nothing is highlighted to tap). Reuses
    /// `applyCorrectionChoice` so it's fixed in this note (if the text is actually present)
    /// and promoted into memory the same way any other accepted correction is.
    private func reportCorrection(wrongText: String, correctText: String, kind: CorrectionKind) {
        let trimmedWrong = wrongText.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCorrect = correctText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedWrong.isEmpty, !trimmedCorrect.isEmpty, trimmedWrong != trimmedCorrect else { return }
        applyCorrectionChoice(NoteCorrection(wrongText: trimmedWrong, correctText: trimmedCorrect, kind: kind), chosenText: trimmedCorrect)
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

struct TranscriptSection: Identifiable, Equatable {
    let id: Int
    let speaker: String
    let text: String
}

/// Groups the transcript into one section per speaker turn, merging consecutive lines from
/// the same speaker. Handles both the label-then-newline format ("SPEAKER_0:\ntext") and the
/// inline format Gemini actually produces ("SPEAKER_0: text" on one line) — a parser written
/// only for the former silently produced a single giant unlabeled section for the latter,
/// which is why the transcript view fell back to flat, unformatted text.
func transcriptSections(from text: String) -> [TranscriptSection] {
    var sections: [TranscriptSection] = []
    var currentSpeaker: String?
    var currentLines: [String] = []

    func appendCurrent() {
        let content = currentLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty, let speaker = currentSpeaker else { return }
        sections.append(TranscriptSection(id: sections.count, speaker: speaker, text: content))
        currentLines.removeAll(keepingCapacity: true)
    }

    for line in text.components(separatedBy: .newlines) {
        if let (speaker, rest) = speakerPrefix(of: line) {
            if speaker != currentSpeaker {
                appendCurrent()
                currentSpeaker = speaker
            }
            if !rest.isEmpty { currentLines.append(rest) }
        } else if !line.trimmingCharacters(in: .whitespaces).isEmpty {
            currentLines.append(line)
        }
    }
    appendCurrent()
    return sections
}

/// If `line` starts with a `SPEAKER_<digits>:` label, returns that label and whatever text
/// follows the colon on the same line (possibly empty). Otherwise `nil`.
func speakerPrefix(of line: String) -> (speaker: String, rest: String)? {
    guard let colonIndex = line.firstIndex(of: ":") else { return nil }
    let label = String(line[line.startIndex..<colonIndex])
    guard label.hasPrefix("SPEAKER_"), !label.dropFirst("SPEAKER_".count).isEmpty,
          label.dropFirst("SPEAKER_".count).allSatisfy(\.isNumber) else { return nil }
    let rest = line[line.index(after: colonIndex)...].trimmingCharacters(in: .whitespaces)
    return (label, rest)
}

/// Renders every turn of the transcript as a color-coded conversation row — each unique
/// speaker gets a stable accent color (assigned in order of first appearance) so a reader
/// can follow who's talking at a glance without clicking through turns one at a time.
private struct TranscriptConversationView: View {
    let sections: [TranscriptSection]
    let reduceMotion: Bool

    private static let speakerPalette: [Color] = [
        AnLuongPalette.clay, AnLuongPalette.mistBlue, AnLuongPalette.sage,
        AnLuongPalette.mutedInk, AnLuongPalette.clayDark, AnLuongPalette.mistBlueDark
    ]

    private var speakerColors: [String: Color] {
        var colors: [String: Color] = [:]
        for section in sections where colors[section.speaker] == nil {
            colors[section.speaker] = Self.speakerPalette[colors.count % Self.speakerPalette.count]
        }
        return colors
    }

    var body: some View {
        let colors = speakerColors
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Speaker transcript")
                        .font(AnLuongTypography.body(12).weight(.semibold))
                        .foregroundStyle(AnLuongPalette.mutedInk)
                    Spacer()
                    Text("\(sections.count) turns")
                        .font(AnLuongTypography.mono(10))
                        .foregroundStyle(AnLuongPalette.mutedInk.opacity(0.72))
                }
                .padding(.bottom, 20)

                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(sections) { section in
                        turnRow(section, color: colors[section.speaker] ?? AnLuongPalette.mutedInk)
                    }
                }
            }
            .padding(30)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity)
            .modifier(ArtifactReveal(reduceMotion: reduceMotion))
        }
        .scrollIndicators(.hidden)
        .background(AnLuongPalette.readingSurface)
    }

    private func turnRow(_ section: TranscriptSection, color: Color) -> some View {
        HStack(alignment: .top, spacing: 14) {
            speakerBadge(section.speaker, color: color)

            VStack(alignment: .leading, spacing: 5) {
                Text(displayName(for: section.speaker))
                    .font(AnLuongTypography.body(12).weight(.bold))
                    .foregroundStyle(color)
                    .tracking(0.2)
                Text(section.text)
                    .font(AnLuongTypography.body(15))
                    .foregroundStyle(AnLuongPalette.graphite.opacity(0.88))
                    .lineSpacing(5)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func speakerBadge(_ speaker: String, color: Color) -> some View {
        Circle()
            .fill(color.opacity(0.22))
            .frame(width: 30, height: 30)
            .overlay {
                Text(initial(for: speaker))
                    .font(AnLuongTypography.body(12).weight(.bold))
                    .foregroundStyle(color)
            }
    }

    private func displayName(for speaker: String) -> String {
        guard let number = speaker.split(separator: "_").last else { return speaker }
        return "Speaker \(number)"
    }

    private func initial(for speaker: String) -> String {
        guard let number = speaker.split(separator: "_").last else { return "?" }
        return String(number.prefix(2))
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
    let onCorrectionResolved: ((NoteCorrection, String?) -> Void)?
    let terms: [TermHighlight]
    let onTermCorrectionSubmitted: ((TermHighlight, String) -> Void)?

    init(
        url: URL?,
        emptyTitle: String,
        emptyMessage: String,
        reduceMotion: Bool,
        rendersMarkdown: Bool = false,
        corrections: [NoteCorrection] = [],
        onCorrectionResolved: ((NoteCorrection, String?) -> Void)? = nil,
        terms: [TermHighlight] = [],
        onTermCorrectionSubmitted: ((TermHighlight, String) -> Void)? = nil
    ) {
        self.url = url
        self.text = nil
        self.emptyTitle = emptyTitle
        self.emptyMessage = emptyMessage
        self.reduceMotion = reduceMotion
        self.rendersMarkdown = rendersMarkdown
        self.corrections = corrections
        self.onCorrectionResolved = onCorrectionResolved
        self.terms = terms
        self.onTermCorrectionSubmitted = onTermCorrectionSubmitted
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
        self.onCorrectionResolved = nil
        self.terms = []
        self.onTermCorrectionSubmitted = nil
    }

    var body: some View {
        if let content = resolvedText {
            if rendersMarkdown {
                MarkdownDocumentView(
                    markdown: content,
                    reduceMotion: reduceMotion,
                    corrections: corrections,
                    onCorrectionResolved: onCorrectionResolved,
                    terms: terms,
                    onTermCorrectionSubmitted: onTermCorrectionSubmitted
                )
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
    var onCorrectionResolved: ((NoteCorrection, String?) -> Void)? = nil
    var terms: [TermHighlight] = []
    var onTermCorrectionSubmitted: ((TermHighlight, String) -> Void)? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                documentMasthead

                LazyVStack(alignment: .leading, spacing: 17) {
                    ForEach(Array(AnLuongMarkdown.parse(markdown).enumerated()), id: \.offset) { _, block in
                        MarkdownBlockView(
                            block: block,
                            corrections: corrections,
                            onCorrectionResolved: onCorrectionResolved,
                            terms: terms,
                            onTermCorrectionSubmitted: onTermCorrectionSubmitted
                        )
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
    var onCorrectionResolved: ((NoteCorrection, String?) -> Void)? = nil
    var terms: [TermHighlight] = []
    var onTermCorrectionSubmitted: ((TermHighlight, String) -> Void)? = nil
    @State private var activeCorrection: NoteCorrection?
    @State private var activeTerm: TermHighlight?

    var body: some View {
        content
            // Attached per-block (not once for the whole scrollable note) so a tapped link's
            // popover anchors near where it was actually tapped, instead of relative to the
            // top of a note that can be thousands of pixels tall.
            .environment(\.openURL, OpenURLAction { url in
                if url.scheme == "anluong-correction", let id = url.host,
                   let correction = corrections.first(where: { $0.id == id }) {
                    activeCorrection = correction
                    return .handled
                }
                if url.scheme == "anluong-term", let id = url.host,
                   let term = terms.first(where: { $0.id == id }) {
                    activeTerm = term
                    return .handled
                }
                return .discarded
            })
            .popover(item: $activeCorrection) { correction in
                CorrectionPickerView(
                    correction: correction,
                    onChoose: { chosenText in onCorrectionResolved?(correction, chosenText) },
                    onKeepOriginal: { onCorrectionResolved?(correction, nil) }
                )
            }
            .popover(item: $activeTerm) { term in
                TermExplainView(
                    term: term,
                    onSubmitCorrection: { chosenText in onTermCorrectionSubmitted?(term, chosenText) }
                )
            }
    }

    @ViewBuilder
    private var content: some View {
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
        let withCorrections = wrapCorrectionsAsLinks(in: text, corrections: corrections)
        let highlighted = wrapTermsAsLinks(in: withCorrections, terms: terms)
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

/// A word/name that Gemini got wrong but that isn't recognized as a glossary term or
/// participant at all — so nothing is highlighted in the note for the user to tap. This form
/// is the fallback entry point: the user types the wrong text as it appears in the note and
/// what it should say instead, and that's stored the same way a tapped-term correction is.
private struct ReportCorrectionView: View {
    let onSubmit: (String, String, CorrectionKind) -> Void
    @State private var wrongText = ""
    @State private var correctText = ""
    @State private var kind: CorrectionKind = .glossaryTerm
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Report a wrong word").font(.headline)
            Text("For a word or name that wasn't recognized at all — type it exactly as it appears in the note, and what it should say instead.")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                Text("As written in the note").font(.caption.weight(.semibold))
                TextField("e.g. Serenity", text: $wrongText)
                    .textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Correct spelling").font(.caption.weight(.semibold))
                TextField("e.g. Celesnity", text: $correctText)
                    .textFieldStyle(.roundedBorder)
            }
            Picker("Kind", selection: $kind) {
                Text("Term / name").tag(CorrectionKind.glossaryTerm)
                Text("Participant").tag(CorrectionKind.participantName)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                Button("Save") {
                    onSubmit(wrongText, correctText, kind)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    wrongText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || correctText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            }
        }
        .padding(20)
        .frame(width: 320)
    }
}

private struct TermExplainView: View {
    let term: TermHighlight
    let onSubmitCorrection: (String) -> Void
    @State private var isEditingCorrection = false
    @State private var correctionInput = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Text(badge).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            if let snippet {
                Text("\"\(snippet)\"").font(.subheadline).foregroundStyle(.secondary).lineLimit(4)
            }
            if !aliases.isEmpty {
                Text("Also heard as: \(aliases.joined(separator: ", "))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider().padding(.vertical, 2)

            if isEditingCorrection {
                Text("Correct spelling:").font(.caption).foregroundStyle(.secondary)
                TextField("Type the correct word…", text: $correctionInput)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(submitCorrection)
                HStack {
                    Button("Cancel") { isEditingCorrection = false }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Save", action: submitCorrection)
                        .buttonStyle(.borderedProminent)
                        .disabled(correctionInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } else {
                Button("Not correct? Fix it…") {
                    correctionInput = ""
                    isEditingCorrection = true
                }
                .buttonStyle(.plain)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
            }
        }
        .padding(16)
        .frame(width: 280, alignment: .leading)
    }

    private func submitCorrection() {
        let trimmed = correctionInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onSubmitCorrection(trimmed)
        dismiss()
    }

    private var title: String {
        switch term.kind {
        case .glossary(let entry): return entry.term
        case .participant(let participant): return participant.name
        }
    }

    private var badge: String {
        switch term.kind {
        case .glossary(let entry): return entry.category == .project ? "Project term" : "Jargon"
        case .participant: return "Participant"
        }
    }

    private var snippet: String? {
        switch term.kind {
        case .glossary(let entry): return entry.snippet
        case .participant(let participant): return participant.snippet
        }
    }

    private var aliases: [String] {
        switch term.kind {
        case .glossary(let entry): return entry.aliases
        case .participant(let participant): return participant.aliases
        }
    }
}

