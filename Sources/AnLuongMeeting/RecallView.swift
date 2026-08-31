import SwiftUI

struct RecallMessage: Identifiable {
    enum Role { case user, assistant }

    let id = UUID()
    let role: Role
    let text: String
    let citedMeetingIDs: [String]

    init(role: Role, text: String, citedMeetingIDs: [String] = []) {
        self.role = role
        self.text = text
        self.citedMeetingIDs = citedMeetingIDs
    }
}

struct RecallView: View {
    @ObservedObject var engine: RecordingEngine
    let meetings: [MeetingRecord]
    let onSelectMeeting: (String) -> Void

    @State private var messages: [RecallMessage] = []
    @State private var draft = ""
    @State private var isSearching = false
    @State private var indexStatus: (indexed: Int, total: Int) = (0, 0)
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(AnLuongTheme.secondary(for: colorScheme).opacity(0.2))
            conversation
            Divider().overlay(AnLuongTheme.secondary(for: colorScheme).opacity(0.2))
            inputBar
        }
        .background(AnLuongTheme.canvas(for: colorScheme))
        .onAppear {
            refreshIndexStatus()
            if indexStatus.total > 0, indexStatus.indexed < indexStatus.total {
                engine.reindexAllNotesForRecall()
            }
        }
        .onChange(of: engine.isReindexingRecall) { _, isRunning in
            if !isRunning { refreshIndexStatus() }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Recall")
                    .font(AnLuongTypography.display(22))
                    .foregroundStyle(AnLuongTheme.primary(for: colorScheme))
                indexStatusLine
            }
            Spacer()
            Button {
                engine.reindexAllNotesForRecall()
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .rotationEffect(.degrees(engine.isReindexingRecall ? 360 : 0))
                    .animation(
                        engine.isReindexingRecall
                            ? .linear(duration: 1).repeatForever(autoreverses: false)
                            : .default,
                        value: engine.isReindexingRecall
                    )
            }
            .buttonStyle(.plain)
            .foregroundStyle(AnLuongTheme.secondary(for: colorScheme))
            .disabled(engine.isReindexingRecall || apiKeyMissing)
            .help("Re-index all meetings for Recall")
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
    }

    @ViewBuilder
    private var indexStatusLine: some View {
        if engine.isReindexingRecall {
            Text("Indexing meetings… \(engine.reindexProgress.current)/\(engine.reindexProgress.total)")
                .font(AnLuongTypography.body(11))
                .foregroundStyle(AnLuongTheme.secondary(for: colorScheme))
        } else if indexStatus.total == 0 {
            Text("No meeting notes yet.")
                .font(AnLuongTypography.body(11))
                .foregroundStyle(AnLuongTheme.secondary(for: colorScheme))
        } else if indexStatus.indexed < indexStatus.total {
            Text("\(indexStatus.indexed)/\(indexStatus.total) meetings indexed")
                .font(AnLuongTypography.body(11))
                .foregroundStyle(.orange)
        } else {
            Text("All \(indexStatus.total) meetings indexed")
                .font(AnLuongTypography.body(11))
                .foregroundStyle(AnLuongTheme.secondary(for: colorScheme))
        }
    }

    // MARK: - Conversation

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if messages.isEmpty {
                        emptyState
                    }
                    ForEach(messages) { message in
                        messageBubble(message).id(message.id)
                    }
                    if isSearching {
                        typingIndicator.id("typing")
                    }
                }
                .padding(22)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: messages.count) { _, _ in scrollToBottom(proxy) }
            .onChange(of: isSearching) { _, _ in scrollToBottom(proxy) }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Ask anything about your past meetings.")
                .font(AnLuongTypography.body(14).weight(.medium))
                .foregroundStyle(AnLuongTheme.primary(for: colorScheme))
            Text("\u{201c}What did we decide about pricing last month?\u{201d}")
                .font(AnLuongTypography.body(12))
                .foregroundStyle(AnLuongTheme.secondary(for: colorScheme))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 40)
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation {
            if isSearching {
                proxy.scrollTo("typing", anchor: .bottom)
            } else if let last = messages.last {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }

    @ViewBuilder
    private func messageBubble(_ message: RecallMessage) -> some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 40)
                Text(message.text)
                    .font(AnLuongTypography.body(13))
                    .foregroundStyle(AnLuongPalette.ivoryBright)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(AnLuongPalette.graphite, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)

        case .assistant:
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 10) {
                    markdownBubbleContent(message.text)
                        .foregroundStyle(AnLuongTheme.primary(for: colorScheme))
                        .textSelection(.enabled)

                    if !message.citedMeetingIDs.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(message.citedMeetingIDs, id: \.self) { id in
                                if let meeting = meetings.first(where: { $0.id == id }) {
                                    Button {
                                        onSelectMeeting(id)
                                    } label: {
                                        Label(meeting.displayName, systemImage: "doc.text")
                                    }
                                    .buttonStyle(.plain)
                                    .font(AnLuongTypography.body(11).weight(.medium))
                                    .foregroundStyle(AnLuongPalette.clay)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    AnLuongTheme.controlSurface(for: colorScheme),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
                Spacer(minLength: 40)
            }
        }
    }

    /// Renders an assistant answer's Markdown (headings, bullets, bold/italic) instead of
    /// dumping raw `#`/`-`/`**` syntax into the bubble — reuses the same block parser the note
    /// reader already uses, at chat-appropriate sizing.
    @ViewBuilder
    private func markdownBubbleContent(_ text: String) -> some View {
        let blocks = AnLuongMarkdown.parse(text)
        if blocks.isEmpty {
            Text(text).font(AnLuongTypography.body(13))
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    markdownBubbleBlock(block)
                }
            }
        }
    }

    @ViewBuilder
    private func markdownBubbleBlock(_ block: AnLuongMarkdownBlock) -> some View {
        switch block {
        case .heading(_, let text):
            inlineText(text).font(AnLuongTypography.body(13).weight(.bold))
        case .paragraph(let text):
            inlineText(text).font(AnLuongTypography.body(13))
        case .unorderedList(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 6) {
                        Text("•").font(AnLuongTypography.body(13))
                        inlineText(item).font(AnLuongTypography.body(13))
                    }
                }
            }
        case .orderedList(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .top, spacing: 6) {
                        Text("\(index + 1).").font(AnLuongTypography.body(13))
                        inlineText(item).font(AnLuongTypography.body(13))
                    }
                }
            }
        case .quote(let text):
            inlineText(text).font(AnLuongTypography.body(13).italic())
        case .code(let text):
            Text(text).font(AnLuongTypography.mono(12))
        case .divider:
            Divider()
        }
    }

    /// Renders inline `**bold**`/`*italic*`/`` `code` `` within a block's text, falling back to
    /// plain text if the fragment isn't valid inline Markdown.
    private func inlineText(_ text: String) -> Text {
        if let attributed = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return Text(attributed)
        }
        return Text(text)
    }

    private var typingIndicator: some View {
        HStack {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Searching your meetings…")
                    .font(AnLuongTypography.body(12))
                    .foregroundStyle(AnLuongTheme.secondary(for: colorScheme))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                AnLuongTheme.controlSurface(for: colorScheme),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
            Spacer(minLength: 40)
        }
    }

    // MARK: - Input bar

    private var inputBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            if apiKeyMissing {
                Text("Enter a Gemini API key before using Recall.")
                    .font(AnLuongTypography.body(11))
                    .foregroundStyle(AnLuongTheme.secondary(for: colorScheme))
            }
            HStack(spacing: 10) {
                TextField("Ask about your meetings…", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(AnLuongTypography.body(13))
                    .foregroundStyle(AnLuongTheme.primary(for: colorScheme))
                    .lineLimit(1...4)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(
                        AnLuongTheme.controlSurface(for: colorScheme),
                        in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                    )
                    .disabled(isSearching || apiKeyMissing)
                    .onSubmit(submit)

                Button(action: submit) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(canSubmit ? AnLuongPalette.clay : AnLuongTheme.secondary(for: colorScheme).opacity(0.4))
                }
                .buttonStyle(.plain)
                .disabled(!canSubmit)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
    }

    private var canSubmit: Bool {
        !isSearching && !apiKeyMissing && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var apiKeyMissing: Bool {
        engine.geminiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func refreshIndexStatus() {
        indexStatus = engine.recallIndexStatus()
    }

    private func submit() {
        guard canSubmit else { return }
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = ""
        messages.append(RecallMessage(role: .user, text: question))
        isSearching = true
        Task {
            do {
                let result = try await engine.answerRecallQuestion(question: question, meetings: meetings)
                await MainActor.run {
                    messages.append(RecallMessage(role: .assistant, text: result.text, citedMeetingIDs: result.citedMeetingIDs))
                    isSearching = false
                    refreshIndexStatus()
                }
            } catch {
                await MainActor.run {
                    messages.append(RecallMessage(role: .assistant, text: error.localizedDescription))
                    isSearching = false
                }
            }
        }
    }
}
