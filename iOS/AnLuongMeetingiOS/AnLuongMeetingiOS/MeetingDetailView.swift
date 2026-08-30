// Hallmark · pre-emit critique: P5 H5 E4 S5 R5 V5 · native iOS workbench · one-title hierarchy · no custom motion
import SwiftUI
import AnLuongMeetingCore

struct IOSMeetingDetailPresentation: Equatable {
    let navigationTitle: String
    let contentTitle: String?
    let artifactLabel: String

    init(meeting: MeetingRecord, tab: IOSDetailTab) {
        navigationTitle = meeting.displayName
        contentTitle = nil
        artifactLabel = tab == .meetingNote ? "Meeting note" : "Transcript"
    }
}

struct IOSMeetingDetailView: View {
    let meeting: MeetingRecord
    @ObservedObject var model: IOSLibraryViewModel
    @ObservedObject var pending: IOSPendingWorkCoordinator
    @State private var tab: IOSDetailTab = .meetingNote
    @State private var showRename = false
    @State private var showDelete = false
    @State private var name = ""
    @State private var corrections: [NoteCorrection] = []
    @State private var activeCorrection: NoteCorrection?
    @State private var correctionError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                processingStatus
                artifactTabs
                artifact
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(presentation.navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Section("Regenerate") {
                        Button("Transcript", systemImage: "text.quote") {
                            pending.regenerate(record: meeting, mode: .transcriptOnly)
                        }
                        .disabled(!IOSMeetingActionAvailability.isEnabled(.regenerateTranscript, meeting: meeting, apiKey: apiKey, isBusy: pending.processingState.isBusy))

                        Button("Meeting note", systemImage: "note.text") {
                            pending.regenerate(record: meeting, mode: .noteOnly)
                        }
                        .disabled(!IOSMeetingActionAvailability.isEnabled(.regenerateNote, meeting: meeting, apiKey: apiKey, isBusy: pending.processingState.isBusy))

                        Button("Transcript + note", systemImage: "arrow.clockwise") {
                            pending.regenerate(record: meeting, mode: .both)
                        }
                        .disabled(!IOSMeetingActionAvailability.isEnabled(.regenerateBoth, meeting: meeting, apiKey: apiKey, isBusy: pending.processingState.isBusy))
                    }
                    if pending.activeRecordingURL == meeting.recordingURL, pending.processingState.isBusy {
                        Button("Cancel processing", systemImage: "xmark.circle", role: .cancel) {
                            pending.cancelProcessing()
                        }
                    }
                    Section("Share") {
                        ShareLink(item: meeting.recordingURL) { Label("Recording", systemImage: "waveform") }
                        if let transcriptURL = meeting.transcriptURL {
                            ShareLink(item: transcriptURL) { Label("Transcript", systemImage: "text.quote") }
                        }
                        if let noteURL = meeting.meetingNoteURL {
                            ShareLink(item: noteURL) { Label("Meeting note", systemImage: "note.text") }
                        }
                    }
                    Button("Rename", systemImage: "pencil") { name = meeting.displayName; showRename = true }
                    Button("Delete Permanently", systemImage: "trash", role: .destructive) { showDelete = true }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .alert("Rename meeting", isPresented: $showRename) {
            TextField("Meeting name", text: $name)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { model.rename(meeting, to: name) }
        }
        .confirmationDialog("Delete \(meeting.displayName)?", isPresented: $showDelete, titleVisibility: .visible) {
            Button("Delete Permanently", role: .destructive) { model.delete(meeting) }
        }
        .task { loadCorrections() }
        .sheet(item: $activeCorrection) { correction in
            CorrectionPickerView(
                correction: correction,
                onChoose: { chosenText in applyCorrectionChoice(correction, chosenText: chosenText) },
                onKeepOriginal: { applyCorrectionChoice(correction, chosenText: nil) }
            )
            .presentationDetents([.height(280)])
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
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: statusIcon)
                .font(.title3.weight(.semibold))
                .foregroundStyle(statusColor)
                .frame(width: 38, height: 38)
                .background(statusColor.opacity(0.14), in: Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text(statusTitle)
                    .font(.headline)
                Text(metadataLine)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var artifactTabs: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(presentation.artifactLabel)
                    .font(.headline)
                Spacer()
                Text("View")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Picker("Artifact", selection: $tab) {
                Label("Meeting note", systemImage: "note.text")
                    .tag(IOSDetailTab.meetingNote)
                Label("Transcript", systemImage: "text.quote")
                    .tag(IOSDetailTab.transcript)
            }
            .pickerStyle(.segmented)
        }
    }

    @ViewBuilder
    private var processingStatus: some View {
        if pending.activeRecordingURL == meeting.recordingURL {
            switch pending.processingState {
            case .processing(let mode, let current, let total):
                VStack(alignment: .leading, spacing: 10) {
                    Label(mode.statusTitle, systemImage: "arrow.triangle.2.circlepath")
                        .font(.headline)
                    if total > 0 {
                        ProgressView(value: Double(current), total: Double(total))
                        Text("Segment \(current) of \(total)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ProgressView()
                    }
                    Text(pending.progressMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .processingPanel()
            case .generatingMeetingNote(let mode):
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text(mode.statusTitle).font(.subheadline.weight(.medium))
                    }
                    Text(pending.progressMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .processingPanel()
            case .failed(let message):
                VStack(alignment: .leading, spacing: 10) {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.subheadline)
                    Button("Retry", systemImage: "arrow.clockwise") { pending.retryLastOperation() }
                        .buttonStyle(.borderedProminent)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
            case .idle, .completed:
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private var artifact: some View {
        let url = tab == .meetingNote ? meeting.meetingNoteURL : meeting.transcriptURL
        if let url, let text = try? String(contentsOf: url, encoding: .utf8) {
            MarkdownDocumentView(
                markdown: text,
                corrections: tab == .meetingNote ? corrections : [],
                onCorrectionTap: { activeCorrection = $0 }
            )
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.background, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        } else {
            VStack(spacing: 12) {
                ContentUnavailableView(
                    tab == .meetingNote ? "Meeting note unavailable" : "Transcript unavailable",
                    systemImage: "doc.text",
                    description: Text("This artifact has not been generated yet.")
                )
                Button("Regenerate \(presentation.artifactLabel)", systemImage: "arrow.clockwise") {
                    regenerateSelectedArtifact()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canRegenerateSelectedArtifact)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 22)
            .background(.background, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    private var presentation: IOSMeetingDetailPresentation {
        IOSMeetingDetailPresentation(meeting: meeting, tab: tab)
    }

    private var metadataLine: String {
        let date = meeting.modifiedAt.formatted(date: .abbreviated, time: .shortened)
        guard let duration = meeting.duration else { return date }
        return "\(date) · \(durationTitle(duration))"
    }

    private var statusIcon: String {
        switch meeting.status {
        case .ready: return "checkmark.circle.fill"
        case .partial: return "exclamationmark.circle.fill"
        case .processing: return "arrow.triangle.2.circlepath"
        }
    }

    private var statusColor: Color {
        switch meeting.status {
        case .ready: return .green
        case .partial: return .orange
        case .processing: return .blue
        }
    }

    private var canRegenerateSelectedArtifact: Bool {
        let action: IOSMeetingAction = tab == .meetingNote ? .regenerateNote : .regenerateTranscript
        return IOSMeetingActionAvailability.isEnabled(
            action,
            meeting: meeting,
            apiKey: apiKey,
            isBusy: pending.processingState.isBusy
        )
    }

    private func regenerateSelectedArtifact() {
        let mode: GeminiRegenerationMode = tab == .meetingNote ? .noteOnly : .transcriptOnly
        pending.regenerate(record: meeting, mode: mode)
    }

    private func durationTitle(_ duration: TimeInterval) -> String {
        String(format: "%d:%02d", Int(duration) / 60, Int(duration) % 60)
    }

    private func loadCorrections() {
        guard let noteURL = meeting.meetingNoteURL else { corrections = []; return }
        let baseName = noteURL.lastPathComponent.replacingOccurrences(of: ".meeting-notes.txt", with: "")
        corrections = NoteCorrectionStore(directory: noteURL.deletingLastPathComponent(), baseName: baseName).load()
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

                var memory = pending.memoryStore.load()
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
                try pending.memoryStore.save(memory)
            } else {
                updatedCorrection.status = .keptOriginal
            }

            let baseName = noteURL.lastPathComponent.replacingOccurrences(of: ".meeting-notes.txt", with: "")
            let store = NoteCorrectionStore(directory: noteURL.deletingLastPathComponent(), baseName: baseName)
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

    private var statusTitle: String { meeting.status.rawValue.capitalized }
    private var apiKey: String { IOSAPIKeyStore().load() ?? "" }
}

enum IOSDetailTab: Hashable { case meetingNote, transcript }

enum IOSMeetingAction: Hashable {
    case regenerateTranscript
    case regenerateNote
    case regenerateBoth
    case rename
    case delete
}

enum IOSMeetingActionAvailability {
    static func isEnabled(
        _ action: IOSMeetingAction,
        meeting: MeetingRecord,
        apiKey: String,
        isBusy: Bool
    ) -> Bool {
        let hasAPIKey = !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        switch action {
        case .rename, .delete:
            return true
        case .regenerateTranscript, .regenerateBoth:
            return !isBusy && hasAPIKey
        case .regenerateNote:
            return !isBusy && hasAPIKey && meeting.transcriptURL != nil
        }
    }
}

private extension GeminiRegenerationMode {
    var statusTitle: String {
        switch self {
        case .transcriptOnly: return "Regenerating transcript"
        case .noteOnly: return "Regenerating meeting note"
        case .both: return "Regenerating transcript and note"
        }
    }
}

private extension View {
    func processingPanel() -> some View {
        self
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct CorrectionPickerView: View {
    let correction: NoteCorrection
    let onChoose: (String) -> Void
    let onKeepOriginal: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
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
        .padding()
    }
}
