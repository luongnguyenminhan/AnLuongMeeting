import SwiftUI

struct GlossaryView: View {
    @ObservedObject var engine: RecordingEngine
    @State private var memory: MemoryData
    @State private var newTerm = ""
    @State private var newCategory: GlossaryCategory = .jargon
    @State private var newParticipant = ""
    @State private var mergeChoice: [String: String] = [:]

    init(engine: RecordingEngine) {
        self.engine = engine
        _memory = State(initialValue: engine.memoryStore.load())
    }

    var body: some View {
        Form {
            Section {
                summaryRow
                backfillRow
            } footer: {
                Text("AnLuong Meeting learns names, project/jargon terms, and note-style preferences from your meetings, then reuses them to correct future transcripts and notes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                if memory.glossary.isEmpty {
                    emptyRow("No terms yet — add one below, or generate from past meetings above.")
                }
                ForEach(memory.glossary) { entry in
                    row(
                        title: entry.term,
                        confirmed: entry.confirmed,
                        snippet: entry.snippet,
                        detail: entry.confirmed ? "\(entry.category == .project ? "Project" : "Jargon") · used \(entry.usageCount)× · \(relative(entry.lastUsedAt))" : nil,
                        onAccept: entry.confirmed ? nil : { memory.acceptGlossary(id: entry.id); persist() },
                        onReject: entry.confirmed ? nil : { memory.rejectGlossary(id: entry.id); persist() },
                        onDelete: entry.confirmed ? { memory.glossary.removeAll { $0.id == entry.id }; persist() } : nil
                    )
                }
                HStack {
                    TextField("Add a term", text: $newTerm)
                    Picker("", selection: $newCategory) {
                        Text("Project").tag(GlossaryCategory.project)
                        Text("Jargon").tag(GlossaryCategory.jargon)
                    }
                    .labelsHidden()
                    .frame(width: 100)
                    Button("Add") { addGlossary() }
                        .disabled(newTerm.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("Terms & names")
            } footer: {
                Text("Proper nouns and jargon Gemini tends to mishear or misspell. Corrected spellings are reused as a spelling guide on every future transcription and note.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                if memory.participants.isEmpty {
                    emptyRow("No recurring participants yet.")
                }
                ForEach(memory.participants) { participant in
                    VStack(alignment: .leading, spacing: 4) {
                        row(
                            title: participant.name,
                            confirmed: participant.confirmed,
                            snippet: participant.snippet,
                            detail: participant.confirmed ? "\(participant.meetingCount) meeting\(participant.meetingCount == 1 ? "" : "s") · \(relative(participant.lastSeenAt))" : nil,
                            onAccept: participant.confirmed ? nil : { memory.acceptParticipant(id: participant.id); persist() },
                            onReject: participant.confirmed ? nil : { memory.rejectParticipant(id: participant.id); persist() },
                            onDelete: participant.confirmed ? { memory.participants.removeAll { $0.id == participant.id }; persist() } : nil
                        )
                        if participant.confirmed {
                            let others = memory.participants.filter { $0.id != participant.id && $0.confirmed }
                            if !others.isEmpty {
                                Menu("Merge into…") {
                                    ForEach(others) { other in
                                        Button(other.name) {
                                            memory.mergeParticipants(primaryID: other.id, absorbing: participant.id)
                                            persist()
                                        }
                                    }
                                }
                                .font(.caption)
                            }
                        }
                    }
                }
                HStack {
                    TextField("Add a participant", text: $newParticipant)
                    Button("Add") { addParticipant() }
                        .disabled(newParticipant.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("Participants")
            } footer: {
                Text("People who show up across meetings, so notes reference them consistently.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                if memory.pendingMerges.isEmpty {
                    emptyRow("No possible duplicate people detected.")
                }
                ForEach(memory.pendingMerges) { suggestion in
                    mergeSuggestionRow(suggestion)
                }
            } header: {
                Text("Possible duplicate people")
            } footer: {
                Text("Gemini noticed these names might all refer to the same person. Pick which name to keep.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                if memory.stylePreferences.isEmpty {
                    emptyRow("No learned style preferences yet.")
                }
                ForEach(memory.stylePreferences) { style in
                    row(
                        title: style.note,
                        confirmed: style.confirmed,
                        snippet: style.snippet,
                        detail: nil,
                        onAccept: style.confirmed ? nil : { memory.acceptStyle(id: style.id); persist() },
                        onReject: style.confirmed ? nil : { memory.rejectStyle(id: style.id); persist() },
                        onDelete: style.confirmed ? { memory.stylePreferences.removeAll { $0.id == style.id }; persist() } : nil
                    )
                }
            } header: {
                Text("Note style")
            } footer: {
                Text("Recurring formatting or structure preferences noticed across your meeting notes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(minWidth: 460, minHeight: 560)
        .onChange(of: engine.isBackfillingMemory) { _, isRunning in
            if !isRunning { memory = engine.memoryStore.load() }
        }
    }

    private var summaryRow: some View {
        HStack(spacing: 16) {
            summaryStat(count: memory.glossary.filter(\.confirmed).count, label: "terms")
            summaryStat(count: memory.participants.filter(\.confirmed).count, label: "participants")
            summaryStat(count: memory.stylePreferences.filter(\.confirmed).count, label: "style notes")
            Spacer()
            if memory.pendingCount > 0 {
                Text("\(memory.pendingCount) pending review")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
            }
        }
    }

    private func summaryStat(count: Int, label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("\(count)").font(.title3.weight(.semibold))
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var backfillRow: some View {
        HStack {
            Button {
                engine.backfillMemoryFromExistingMeetings()
            } label: {
                Label("Generate from existing meetings", systemImage: "sparkles")
            }
            .disabled(engine.isBackfillingMemory || engine.geminiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            if engine.isBackfillingMemory {
                ProgressView(value: Double(engine.backfillProgress.current), total: Double(max(engine.backfillProgress.total, 1)))
                    .frame(width: 120)
                Text("\(engine.backfillProgress.current)/\(engine.backfillProgress.total)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func mergeSuggestionRow(_ suggestion: IdentityMergeSuggestion) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(suggestion.names.joined(separator: " / "))
            if let snippet = suggestion.snippet {
                Text(snippet).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Picker("Keep as", selection: Binding(
                get: { mergeChoice[suggestion.id] ?? suggestion.canonicalName ?? suggestion.names.first ?? "" },
                set: { mergeChoice[suggestion.id] = $0 }
            )) {
                ForEach(suggestion.names, id: \.self) { name in Text(name).tag(name) }
            }
            HStack {
                Button("Accept") {
                    let canonical = mergeChoice[suggestion.id] ?? suggestion.canonicalName ?? suggestion.names.first ?? ""
                    memory.acceptMerge(suggestion, canonicalName: canonical)
                    mergeChoice[suggestion.id] = nil
                    persist()
                }
                Button("Reject", role: .destructive) {
                    memory.rejectMerge(suggestion)
                    mergeChoice[suggestion.id] = nil
                    persist()
                }
            }
        }
    }

    @ViewBuilder
    private func emptyRow(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func row(
        title: String,
        confirmed: Bool,
        snippet: String?,
        detail: String?,
        onAccept: (() -> Void)?,
        onReject: (() -> Void)?,
        onDelete: (() -> Void)?
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                if !confirmed {
                    Text("Suggested").font(.caption).foregroundStyle(.orange)
                }
                Spacer()
                if let onAccept { Button("Accept", action: onAccept) }
                if let onReject { Button("Reject", role: .destructive, action: onReject) }
                if let onDelete { Button(role: .destructive, action: onDelete) { Image(systemName: "trash") } }
            }
            if let snippet, !confirmed {
                Text(snippet).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            if let detail {
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func addGlossary() {
        let term = newTerm.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else { return }
        memory.glossary.append(GlossaryEntry(term: term, category: newCategory, source: .manual, confirmed: true))
        newTerm = ""
        persist()
    }

    private func addParticipant() {
        let name = newParticipant.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        memory.participants.append(Participant(name: name, source: .manual, confirmed: true))
        newParticipant = ""
        persist()
    }

    private func persist() {
        try? engine.memoryStore.save(memory)
        engine.refreshPendingMemoryCount()
    }

    private func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
