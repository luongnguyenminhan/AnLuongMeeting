import SwiftUI
import AnLuongMeetingCore

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

/// Cross-meeting Q&A over past meeting notes — the iOS counterpart of macOS's Recall screen.
/// Pushed onto the Library's existing `NavigationStack` (not its own), so a citation tap can use
/// `NavigationLink(value:)` and resolve against the Library's own `navigationDestination`.
struct RecallView: View {
    @ObservedObject var pending: IOSPendingWorkCoordinator

    @State private var meetings: [MeetingRecord] = []
    @State private var messages: [RecallMessage] = []
    @State private var draft = ""
    @State private var isSearching = false
    @State private var streamingMessageID: UUID?
    @State private var indexStatus: (indexed: Int, total: Int) = (0, 0)
    /// Characters received from the network but not yet revealed in the UI — drained at a steady
    /// pace so a reveal doesn't look jumpy when network chunks arrive in bursty, uneven sizes.
    @State private var revealBuffer = ""
    @State private var networkFinished = false

    private var recordingsDirectory: URL { IOSMeetingStorage().recordingsDirectory }
    private var conversationStore: RecallConversationStore { RecallConversationStore(directory: recordingsDirectory) }

    var body: some View {
        VStack(spacing: 0) {
            conversation
            Divider()
            inputBar
        }
        .navigationTitle("Recall")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                indexStatusLine
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    pending.reindexAllNotesForRecall()
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
                .disabled(pending.isReindexingRecall)
                Button(role: .destructive) {
                    clearConversation()
                } label: {
                    Image(systemName: "trash")
                }
                .disabled(messages.isEmpty || isSearching)
            }
        }
        .onAppear {
            reload()
            loadConversation()
            if indexStatus.total > 0, indexStatus.indexed < indexStatus.total {
                pending.reindexAllNotesForRecall()
            }
        }
        .onChange(of: pending.isReindexingRecall) { _, isRunning in
            if !isRunning { refreshIndexStatus() }
        }
    }

    // MARK: - Status

    @ViewBuilder
    private var indexStatusLine: some View {
        if pending.isReindexingRecall {
            Text("Indexing \(pending.reindexProgress.current)/\(pending.reindexProgress.total)…")
                .font(.caption).foregroundStyle(.secondary)
        } else if indexStatus.total == 0 {
            Text("No notes yet").font(.caption).foregroundStyle(.secondary)
        } else if indexStatus.indexed < indexStatus.total {
            Text("\(indexStatus.indexed)/\(indexStatus.total) indexed").font(.caption).foregroundStyle(.orange)
        } else {
            Text("\(indexStatus.total) indexed").font(.caption).foregroundStyle(.secondary)
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
                .padding(16)
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
                .font(.subheadline.weight(.medium))
            Text("\u{201c}What did we decide about pricing last month?\u{201d}")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 24)
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
                    .font(.subheadline)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)

        case .assistant:
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 10) {
                    if message.id == streamingMessageID {
                        // Plain incrementally-appended text while streaming — parsing partial
                        // Markdown mid-stream would flicker on incomplete syntax.
                        Text(message.text.isEmpty ? " " : message.text + " ▍")
                            .font(.subheadline)
                            .animation(.easeOut(duration: 0.12), value: message.text)
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(Markdown.parse(message.text).enumerated()), id: \.offset) { _, block in
                                markdownBubbleBlock(block)
                            }
                        }
                    }

                    if !message.citedMeetingIDs.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(message.citedMeetingIDs, id: \.self) { id in
                                if let meeting = meetings.first(where: { $0.id == id }) {
                                    NavigationLink(value: id) {
                                        Label(meeting.displayName, systemImage: "doc.text")
                                    }
                                    .font(.caption.weight(.medium))
                                }
                            }
                        }
                    }
                }
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                Spacer(minLength: 40)
            }
        }
    }

    @ViewBuilder
    private func markdownBubbleBlock(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            inlineText(text).font(level == 1 ? .subheadline.bold() : .footnote.bold())
        case .paragraph(let text):
            inlineText(text).font(.subheadline)
        case .unorderedList(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(items, id: \.self) { inlineText("•  \($0)").font(.subheadline) }
            }
        case .orderedList(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, text in
                    inlineText("\(index + 1).  \(text)").font(.subheadline)
                }
            }
        case .quote(let text):
            inlineText(text).italic().font(.subheadline)
        case .code(let text):
            Text(text).font(.system(.footnote, design: .monospaced))
                .padding(8).background(.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
        case .divider:
            Divider()
        }
    }

    private func inlineText(_ text: String) -> Text {
        if let attributed = try? AttributedString(markdown: text) { return Text(attributed) }
        return Text(text)
    }

    private var typingIndicator: some View {
        HStack {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Searching your meetings…").font(.footnote).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            Spacer(minLength: 40)
        }
    }

    // MARK: - Input bar

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Ask about your meetings…", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .disabled(isSearching)
                .onSubmit(submit)
            Button(action: submit) {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 26))
            }
            .disabled(!canSubmit)
        }
        .padding(12)
        .background(.bar)
    }

    private var canSubmit: Bool {
        !isSearching && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func reload() {
        meetings = (try? IOSMeetingStorage().scan(processingURL: nil)) ?? []
        refreshIndexStatus()
    }

    private func refreshIndexStatus() {
        indexStatus = pending.recallIndexStatus()
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

    /// Drains `revealBuffer` at a steady pace instead of dumping each network delta straight into
    /// the message the instant it arrives, so a fast, bursty response doesn't look jumpy.
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
                let result = try await pending.answerRecallQuestion(question: question, history: history, meetings: meetings) { delta in
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
