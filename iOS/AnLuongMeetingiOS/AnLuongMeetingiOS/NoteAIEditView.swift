import SwiftUI
import AnLuongMeetingCore

/// A sheet that lets the user edit a meeting note by instructing Gemini in plain language.
/// Gemini runs a tool-calling loop — it can search the note/transcript, check the glossary, flag
/// new terms, and propose targeted find/replace edits — streaming its activity live, closer to
/// watching a coding agent work than waiting for one blob. Nothing is written to disk until the
/// user approves.
struct NoteAIEditSheet: View {
    let noteURL: URL
    let transcriptURL: URL?
    @ObservedObject var pending: IOSPendingWorkCoordinator
    let onApplied: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var instruction = ""
    @State private var noteText = ""
    @State private var turns: [EditTurn] = []
    @State private var excludedPatchIDs: Set<UUID> = []
    @State private var isSending = false

    var body: some View {
        NavigationStack {
            ScrollViewReader { scrollProxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if turns.isEmpty {
                            Text("Tell it what to change about this note — e.g. \"shorten the summary\" or \"fix the typo in the second decision\".")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(turns) { turn in
                            turnView(turn).id(turn.id)
                        }
                    }
                    .padding(16)
                }
                .onChange(of: turns.count) { _, _ in
                    guard let lastID = turns.last?.id else { return }
                    withAnimation { scrollProxy.scrollTo(lastID, anchor: .bottom) }
                }
            }
            .safeAreaInset(edge: .bottom) { composer }
            .navigationTitle("Edit with AI")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .onAppear { noteText = (try? String(contentsOf: noteURL, encoding: .utf8)) ?? "" }
    }

    @ViewBuilder
    private func turnView(_ turn: EditTurn) -> some View {
        let isLatest = turn.id == turns.last?.id
        VStack(alignment: .leading, spacing: 10) {
            Text(turn.instruction)
                .font(.subheadline.weight(.medium))
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            if !turn.statusLines.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(turn.statusLines.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            switch turn.phase {
            case .running:
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Working…").font(.footnote).foregroundStyle(.secondary)
                }
            case .failed(let message):
                Text(message).font(.footnote).foregroundStyle(.red)
            case .done(let summary):
                if turn.patches.isEmpty {
                    Text(summary).font(.footnote).foregroundStyle(.secondary)
                } else if turn.applied {
                    Label("Applied \(turn.patches.count - excludedPatchIDs.count) edit\(turn.patches.count - excludedPatchIDs.count == 1 ? "" : "s")", systemImage: "checkmark.circle.fill")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.green)
                }
            }

            if !turn.patches.isEmpty, !turn.applied {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(turn.patches) { patch in
                        patchCard(patch, isLatest: isLatest)
                    }
                    if isLatest {
                        applyBar(turn)
                    }
                }
            }
        }
    }

    private func patchCard(_ patch: NoteEditPatch, isLatest: Bool) -> some View {
        let isExcluded = excludedPatchIDs.contains(patch.id)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                if isLatest {
                    Button {
                        if isExcluded { excludedPatchIDs.remove(patch.id) } else { excludedPatchIDs.insert(patch.id) }
                    } label: {
                        Image(systemName: isExcluded ? "circle" : "checkmark.circle.fill")
                            .foregroundStyle(isExcluded ? Color.secondary : Color.green)
                    }
                    .buttonStyle(.plain)
                }
                Text(patch.explanation)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.primary)
            }
            if !patch.oldString.isEmpty {
                Text(patch.oldString)
                    .font(.system(.footnote, design: .monospaced))
                    .strikethrough()
                    .foregroundStyle(.red)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            if !patch.newString.isEmpty {
                Text(patch.newString)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(.green)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        }
        .padding(10)
        .opacity(isExcluded ? 0.5 : 1)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func applyBar(_ turn: EditTurn) -> some View {
        let includedCount = turn.patches.filter { !excludedPatchIDs.contains($0.id) }.count
        return HStack {
            Button("Discard", role: .destructive) {
                updateTurn(turn.id) { $0.applied = true }
            }
            Spacer()
            Button("Apply \(includedCount) edit\(includedCount == 1 ? "" : "s")") {
                apply(turn)
            }
            .buttonStyle(.borderedProminent)
            .disabled(includedCount == 0 || isSending)
        }
        .font(.footnote.weight(.medium))
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Tell it what to change…", text: $instruction, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .padding(10)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            Button {
                send()
            } label: {
                Image(systemName: "arrow.up.circle.fill").font(.title2)
            }
            .disabled(instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending)
        }
        .padding(12)
        .background(.bar)
    }

    private func send() {
        let trimmed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSending else { return }
        instruction = ""
        excludedPatchIDs = []
        let turnID = UUID()
        turns.append(EditTurn(id: turnID, instruction: trimmed))
        isSending = true

        let onStatus: @Sendable (String) -> Void = { line in
            Task { @MainActor in updateTurn(turnID) { $0.statusLines.append(line) } }
        }
        let onPatch: @Sendable (NoteEditPatch) -> Void = { patch in
            Task { @MainActor in updateTurn(turnID) { $0.patches.append(patch) } }
        }

        Task {
            do {
                let summary = try await pending.runNoteEditAgent(
                    instruction: trimmed,
                    noteText: noteText,
                    transcriptURL: transcriptURL,
                    onStatus: onStatus,
                    onPatch: onPatch
                )
                await MainActor.run {
                    updateTurn(turnID) { $0.phase = .done(summary: summary) }
                    isSending = false
                }
            } catch {
                await MainActor.run {
                    updateTurn(turnID) { $0.phase = .failed(error.localizedDescription) }
                    isSending = false
                }
            }
        }
    }

    private func apply(_ turn: EditTurn) {
        var updated = noteText
        var appliedCount = 0
        for patch in turn.patches where !excludedPatchIDs.contains(patch.id) {
            guard let range = updated.range(of: patch.oldString) else { continue }
            updated.replaceSubrange(range, with: patch.newString)
            appliedCount += 1
        }
        do {
            try Data(updated.utf8).write(to: noteURL, options: .atomic)
            noteText = updated
            updateTurn(turn.id) { $0.applied = true }
            onApplied()
        } catch {
            updateTurn(turn.id) { $0.phase = .failed(error.localizedDescription) }
        }
    }

    private func updateTurn(_ id: UUID, _ mutate: (inout EditTurn) -> Void) {
        guard let index = turns.firstIndex(where: { $0.id == id }) else { return }
        mutate(&turns[index])
    }
}

private struct EditTurn: Identifiable {
    let id: UUID
    let instruction: String
    var statusLines: [String] = []
    var patches: [NoteEditPatch] = []
    var applied = false
    var phase: Phase = .running

    enum Phase {
        case running
        case failed(String)
        case done(summary: String)
    }
}
