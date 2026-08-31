import SwiftUI

/// A sidebar that lets the user edit a meeting note by instructing Gemini in plain language.
/// Gemini runs a tool-calling loop — it can search the note/transcript, check the glossary, flag
/// new terms, and propose targeted find/replace edits — streaming its activity live, closer to
/// watching a coding agent work than waiting for one blob. Nothing is written to disk until the
/// user approves.
struct NoteAIEditPanel: View {
    let noteURL: URL
    let transcriptURL: URL?
    @ObservedObject var engine: RecordingEngine
    let onClose: () -> Void
    let onApplied: () -> Void

    @State private var instruction = ""
    @State private var noteText = ""
    @State private var turns: [EditTurn] = []
    @State private var excludedPatchIDs: Set<UUID> = []
    @State private var isSending = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(AnLuongPalette.ivory.opacity(0.12))
            ScrollViewReader { scrollProxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(turns) { turn in
                            turnView(turn).id(turn.id)
                        }
                    }
                    .padding(16)
                }
                .onChange(of: turns.count) { _, _ in
                    guard let lastID = turns.last?.id else { return }
                    withAnimation(reduceMotion ? nil : AnLuongMotion.gentle) {
                        scrollProxy.scrollTo(lastID, anchor: .bottom)
                    }
                }
            }
            Divider().overlay(AnLuongPalette.ivory.opacity(0.12))
            composer
        }
        .frame(maxHeight: .infinity)
        .background(AnLuongPalette.graphiteRaised)
        .onAppear { noteText = (try? String(contentsOf: noteURL, encoding: .utf8)) ?? "" }
    }

    private var header: some View {
        HStack {
            Label("Edit with AI", systemImage: "sparkles")
                .font(AnLuongTypography.body(13).weight(.semibold))
                .foregroundStyle(AnLuongPalette.ivory)
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .foregroundStyle(AnLuongPalette.ivory.opacity(0.7))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private func turnView(_ turn: EditTurn) -> some View {
        let isLatest = turn.id == turns.last?.id
        VStack(alignment: .leading, spacing: 10) {
            Text(turn.instruction)
                .font(AnLuongTypography.body(13).weight(.medium))
                .foregroundStyle(AnLuongPalette.ivory)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AnLuongPalette.graphiteSoft, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            if !turn.statusLines.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(turn.statusLines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(AnLuongTypography.body(11))
                            .foregroundStyle(AnLuongPalette.ivory.opacity(0.5))
                    }
                }
            }

            switch turn.phase {
            case .running:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Working…").font(AnLuongTypography.body(12)).foregroundStyle(AnLuongPalette.ivory.opacity(0.65))
                }
            case .failed(let message):
                Text(message).font(AnLuongTypography.body(12)).foregroundStyle(.red)
            case .done(let summary):
                if turn.patches.isEmpty {
                    Text(summary).font(AnLuongTypography.body(12)).foregroundStyle(AnLuongPalette.ivory.opacity(0.65))
                } else if turn.applied {
                    Label("Applied \(turn.patches.count - excludedPatchIDs.count) edit\(turn.patches.count - excludedPatchIDs.count == 1 ? "" : "s")", systemImage: "checkmark.circle.fill")
                        .font(AnLuongTypography.body(12).weight(.medium))
                        .foregroundStyle(AnLuongPalette.sage)
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
                            .foregroundStyle(isExcluded ? AnLuongPalette.ivory.opacity(0.4) : AnLuongPalette.sage)
                    }
                    .buttonStyle(.plain)
                }
                Text(patch.explanation)
                    .font(AnLuongTypography.body(12).weight(.medium))
                    .foregroundStyle(AnLuongPalette.ivory.opacity(0.85))
            }
            if !patch.oldString.isEmpty {
                Text(patch.oldString)
                    .font(AnLuongTypography.mono(11))
                    .strikethrough()
                    .foregroundStyle(.red.opacity(0.9))
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            if !patch.newString.isEmpty {
                Text(patch.newString)
                    .font(AnLuongTypography.mono(11))
                    .foregroundStyle(AnLuongPalette.sage)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(AnLuongPalette.sage.opacity(0.14), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        }
        .padding(10)
        .opacity(isExcluded ? 0.5 : 1)
        .background(AnLuongPalette.graphiteSoft, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func applyBar(_ turn: EditTurn) -> some View {
        let includedCount = turn.patches.filter { !excludedPatchIDs.contains($0.id) }.count
        return HStack {
            Button("Discard", role: .destructive) {
                updateTurn(turn.id) { $0.applied = true }
            }
            .buttonStyle(.plain)
            .foregroundStyle(AnLuongPalette.ivory.opacity(0.7))
            Spacer()
            Button("Apply \(includedCount) edit\(includedCount == 1 ? "" : "s")") {
                apply(turn)
            }
            .buttonStyle(.borderedProminent)
            .tint(AnLuongPalette.clay)
            .disabled(includedCount == 0 || isSending)
        }
        .font(AnLuongTypography.body(12).weight(.medium))
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Tell it what to change…", text: $instruction, axis: .vertical)
                .textFieldStyle(.plain)
                .font(AnLuongTypography.body(13))
                .foregroundStyle(AnLuongPalette.ivory)
                .lineLimit(1...4)
                .padding(10)
                .background(AnLuongPalette.graphiteSoft, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .onSubmit(send)
            HStack {
                Spacer()
                Button("Send", action: send)
                    .buttonStyle(.borderedProminent)
                    .tint(AnLuongPalette.clay)
                    .disabled(instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending)
            }
        }
        .padding(16)
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
                let summary = try await engine.runNoteEditAgent(
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
