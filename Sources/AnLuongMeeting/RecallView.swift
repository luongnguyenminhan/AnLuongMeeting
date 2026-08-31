import SwiftUI

struct RecallMessage: Identifiable {
    enum Role { case user, assistant }

    let id: UUID
    let role: Role
    var text: String
    var citedMeetingIDs: [String]

    init(id: UUID = UUID(), role: Role, text: String, citedMeetingIDs: [String] = []) {
        self.id = id
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
    @State private var streamingMessageID: UUID?
    @State private var indexStatus: (indexed: Int, total: Int) = (0, 0)
    /// Characters received from the network but not yet revealed in the UI. Network chunks
    /// arrive in bursty, uneven sizes (a whole sentence at once, then nothing for a second) —
    /// buffering and draining this at a steady pace is what makes the reveal feel smooth rather
    /// than jumpy, independent of how the underlying deltas happened to be sized.
    @State private var revealBuffer = ""
    @State private var networkFinished = false
    @Environment(\.colorScheme) private var colorScheme

    private var conversationStore: RecallConversationStore {
        RecallConversationStore(directory: engine.recordingsDirectory)
    }

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
            loadConversation()
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
                clearConversation()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .foregroundStyle(AnLuongTheme.secondary(for: colorScheme))
            .disabled(messages.isEmpty || isSearching)
            .help("Clear conversation")

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
                    if isSearching && streamingMessageID == nil {
                        typingIndicator.id("typing")
                    }
                }
                .padding(22)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: messages.count) { _, _ in scrollToBottom(proxy) }
            .onChange(of: messages.last?.text) { _, _ in scrollToBottom(proxy) }
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
            if let last = messages.last {
                proxy.scrollTo(last.id, anchor: .bottom)
            } else if isSearching {
                proxy.scrollTo("typing", anchor: .bottom)
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
                    if message.id == streamingMessageID {
                        // Rendered as plain incrementally-appended text while streaming — parsing
                        // partial Markdown mid-stream would flicker on incomplete syntax. Swaps to
                        // the formatted renderer below once the stream finishes.
                        (Text(message.text.isEmpty ? " " : message.text) + Text(" ▍").foregroundStyle(AnLuongPalette.clay))
                            .font(AnLuongTypography.body(13))
                            .animation(.easeOut(duration: 0.12), value: message.text)
                    } else {
                        markdownBubbleContent(message.text)
                    }

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
                .foregroundStyle(AnLuongTheme.primary(for: colorScheme))
                .textSelection(.enabled)
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
        case .heading(let level, let text):
            inlineText(text)
                .font(AnLuongTypography.body(level == 1 ? 15 : 13.5).weight(.bold))
                .foregroundStyle(AnLuongPalette.clay)
                .padding(.top, 4)
        case .paragraph(let text):
            inlineText(text).font(AnLuongTypography.body(13)).lineSpacing(3)
        case .unorderedList(let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Circle()
                            .fill(AnLuongPalette.clay.opacity(0.7))
                            .frame(width: 4, height: 4)
                            .offset(y: -3)
                        inlineText(item).font(AnLuongTypography.body(13)).lineSpacing(2)
                    }
                }
            }
            .padding(.leading, 2)
        case .orderedList(let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(index + 1).")
                            .font(AnLuongTypography.body(12).weight(.semibold))
                            .foregroundStyle(AnLuongPalette.clay)
                        inlineText(item).font(AnLuongTypography.body(13)).lineSpacing(2)
                    }
                }
            }
        case .quote(let text):
            HStack(alignment: .top, spacing: 8) {
                Rectangle().fill(AnLuongPalette.clay.opacity(0.5)).frame(width: 2)
                inlineText(text).font(AnLuongTypography.body(13).italic())
            }
        case .code(let text):
            Text(text)
                .font(AnLuongTypography.mono(12))
                .padding(8)
                .background(AnLuongPalette.graphite.opacity(0.85), in: RoundedRectangle(cornerRadius: 6))
                .foregroundStyle(AnLuongPalette.ivoryBright)
        case .divider:
            Divider().padding(.vertical, 2)
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

    // MARK: - Persistence

    private func loadConversation() {
        messages = conversationStore.load().map { stored in
            RecallMessage(
                role: stored.role == .user ? .user : .assistant,
                text: stored.text,
                citedMeetingIDs: stored.citedMeetingIDs
            )
        }
    }

    private func persistConversation() {
        let stored = messages.map {
            RecallStoredMessage(role: $0.role == .user ? .user : .assistant, text: $0.text, citedMeetingIDs: $0.citedMeetingIDs)
        }
        try? conversationStore.save(stored)
    }

    private func clearConversation() {
        messages = []
        try? conversationStore.clear()
    }

    /// The last few question/answer pairs already in the transcript, for follow-up questions to
    /// resolve references like "it" or "that" against.
    private var conversationHistory: [RecallTurn] {
        var turns: [RecallTurn] = []
        var pendingQuestion: String?
        for message in messages {
            switch message.role {
            case .user:
                pendingQuestion = message.text
            case .assistant:
                if let question = pendingQuestion {
                    turns.append(RecallTurn(question: question, answerText: message.text))
                    pendingQuestion = nil
                }
            }
        }
        return turns
    }

    // MARK: - Submit

    /// Drains `revealBuffer` at a steady pace instead of dumping each network delta straight
    /// into the message the instant it arrives — network chunks land in bursty, uneven sizes, so
    /// revealing them raw looks jumpy. Speeds up automatically if the buffer is backing up (the
    /// network is outrunning the reveal rate) so a fast response never lags noticeably behind.
    private func runRevealLoop(messageID: UUID) async {
        while !revealBuffer.isEmpty || !networkFinished {
            guard !revealBuffer.isEmpty else {
                try? await Task.sleep(nanoseconds: 20_000_000)
                continue
            }
            let chunkSize = max(1, revealBuffer.count / 6)
            let chunk = String(revealBuffer.prefix(chunkSize))
            revealBuffer.removeFirst(chunk.count)
            if let index = messages.firstIndex(where: { $0.id == messageID }) {
                messages[index].text += chunk
            }
            try? await Task.sleep(nanoseconds: 12_000_000)
        }
    }

    private func submit() {
        guard canSubmit else { return }
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let history = conversationHistory
        draft = ""
        messages.append(RecallMessage(role: .user, text: question))
        persistConversation()

        let assistantMessageID = UUID()
        isSearching = true
        streamingMessageID = nil
        revealBuffer = ""
        networkFinished = false

        Task {
            do {
                let result = try await engine.answerRecallQuestion(question: question, history: history, meetings: meetings) { delta in
                    if streamingMessageID == nil {
                        streamingMessageID = assistantMessageID
                        messages.append(RecallMessage(id: assistantMessageID, role: .assistant, text: ""))
                        Task { await runRevealLoop(messageID: assistantMessageID) }
                    }
                    revealBuffer += delta
                }
                networkFinished = true
                while !revealBuffer.isEmpty { try? await Task.sleep(nanoseconds: 20_000_000) }

                if let index = messages.firstIndex(where: { $0.id == assistantMessageID }) {
                    messages[index].citedMeetingIDs = result.citedMeetingIDs
                } else {
                    messages.append(RecallMessage(id: assistantMessageID, role: .assistant, text: result.text, citedMeetingIDs: result.citedMeetingIDs))
                }
                isSearching = false
                streamingMessageID = nil
                persistConversation()
                refreshIndexStatus()
            } catch {
                networkFinished = true
                while !revealBuffer.isEmpty { try? await Task.sleep(nanoseconds: 20_000_000) }

                if let index = messages.firstIndex(where: { $0.id == assistantMessageID }), !messages[index].text.isEmpty {
                    messages[index].text += "\n\n⚠️ \(error.localizedDescription)"
                } else if let index = messages.firstIndex(where: { $0.id == assistantMessageID }) {
                    messages[index].text = error.localizedDescription
                } else {
                    messages.append(RecallMessage(id: assistantMessageID, role: .assistant, text: error.localizedDescription))
                }
                isSearching = false
                streamingMessageID = nil
                persistConversation()
            }
        }
    }
}
