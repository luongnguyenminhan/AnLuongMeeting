import SwiftUI

struct LibraryView: View {
    @ObservedObject var engine: RecordingEngine
    @StateObject private var library: RecordingLibrary
    @State private var searchText = ""
    @State private var selectedFilter: MeetingFilter = .all
    @State private var selectedMeetingID: String?
    @State private var renameTarget: MeetingRecord?
    @State private var deleteTarget: MeetingRecord?
    @State private var operationError: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    init(engine: RecordingEngine) {
        self.engine = engine
        _library = StateObject(wrappedValue: RecordingLibrary(directory: engine.recordingsDirectory))
    }

    private var visibleRecords: [MeetingRecord] {
        MeetingLibraryIndex.filtered(
            library.records,
            searchText: searchText,
            filter: selectedFilter
        )
    }

    private var selectedMeeting: MeetingRecord? {
        guard let selectedMeetingID else { return nil }
        return library.records.first { $0.id == selectedMeetingID }
    }

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 0) {
                header
                statusStrip
                Divider().overlay(CelesnityTheme.secondary(for: colorScheme).opacity(0.28))
                content
            }
            .background(CelesnityTheme.canvas(for: colorScheme))
            .navigationSplitViewColumnWidth(min: 520, ideal: 680)
        } detail: {
            if let selectedMeeting {
                MeetingDetailView(
                    meeting: selectedMeeting,
                    onRename: { renameTarget = selectedMeeting },
                    onDelete: { deleteTarget = selectedMeeting }
                )
            } else {
                libraryPlaceholder
            }
        }
        .frame(minWidth: 980, minHeight: 620)
        .background(CelesnityTheme.canvas(for: colorScheme))
        .onAppear { refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .celesnityLibraryDidChange)) { _ in
            refresh()
        }
        .sheet(item: $renameTarget) { meeting in
            RenameMeetingSheet(initialName: meeting.displayName) { newName in
                do {
                    try library.rename(meeting, to: newName)
                } catch {
                    operationError = error.localizedDescription
                }
            }
        }
        .confirmationDialog(
            "Permanently delete \(deleteTarget?.displayName ?? "this meeting")?",
            isPresented: Binding(
                get: { deleteTarget != nil },
                set: { if !$0 { deleteTarget = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Permanently", role: .destructive) {
                guard let deleteTarget else { return }
                do {
                    try library.deletePermanently(deleteTarget)
                    if selectedMeetingID == deleteTarget.id {
                        selectedMeetingID = nil
                    }
                } catch {
                    operationError = error.localizedDescription
                }
                self.deleteTarget = nil
            }
            Button("Cancel", role: .cancel) {
                deleteTarget = nil
            }
        } message: {
            Text(deleteMessage)
        }
        .alert(
            "Library operation failed",
            isPresented: Binding(
                get: { operationError != nil },
                set: { if !$0 { operationError = nil } }
            )
        ) {
            Button("OK") { operationError = nil }
        } message: {
            Text(operationError ?? "Please try again.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Library")
                        .font(CelesnityTypography.display(28))
                        .foregroundStyle(CelesnityTheme.primary(for: colorScheme))
                    Text("Your conversations, in context.")
                        .font(CelesnityTypography.body(12))
                        .foregroundStyle(CelesnityTheme.secondary(for: colorScheme))
                }
                Spacer()
                if library.isLoading || library.isMutating {
                    ProgressView()
                        .controlSize(.small)
                        .tint(CelesnityTheme.primary(for: colorScheme))
                        .transition(.opacity)
                }
            }

            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(CelesnityTheme.secondary(for: colorScheme))
                TextField("Search meetings...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(CelesnityTypography.body(13))
                    .foregroundStyle(CelesnityTheme.primary(for: colorScheme))
                    .tint(CelesnityPalette.clay)
                    .accessibilityLabel("Search meetings")
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(CelesnityTheme.secondary(for: colorScheme))
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(CelesnityTheme.controlSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .padding(22)
    }

    private var statusStrip: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4),
            spacing: 8
        ) {
            CelesnityStatusTile(
                title: "All",
                subtitle: "\(library.records.count) meetings",
                icon: "rectangle.stack",
                fill: colorScheme == .dark ? CelesnityPalette.graphiteRaised : CelesnityPalette.readingSurface,
                isSelected: selectedFilter == .all
            ) { select(.all) }

            CelesnityStatusTile(
                title: "Ready",
                subtitle: "\(count(.ready)) complete",
                icon: "checkmark.circle.fill",
                fill: colorScheme == .dark ? CelesnityPalette.sageDark : CelesnityPalette.sage,
                isSelected: selectedFilter == .ready
            ) { select(.ready) }

            CelesnityStatusTile(
                title: "Partial",
                subtitle: "\(count(.partial)) needs attention",
                icon: "exclamationmark.circle",
                fill: colorScheme == .dark ? CelesnityPalette.clayDark : CelesnityPalette.clay,
                isSelected: selectedFilter == .partial
            ) { select(.partial) }

            CelesnityStatusTile(
                title: "Processing",
                subtitle: "\(count(.processing)) working",
                icon: "arrow.triangle.2.circlepath",
                fill: colorScheme == .dark ? CelesnityPalette.mistBlueDark : CelesnityPalette.mistBlue,
                isSelected: selectedFilter == .processing
            ) { select(.processing) }
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 18)
        .opacity(reduceMotion ? 1 : 1)
    }

    @ViewBuilder
    private var content: some View {
        if let errorMessage = library.errorMessage, library.records.isEmpty {
            CelesnityEmptyState(
                title: "Library unavailable",
                message: errorMessage,
                icon: "exclamationmark.triangle",
                actionTitle: "Retry",
                action: refresh
            )
        } else if library.records.isEmpty {
            CelesnityEmptyState(
                title: "No recordings yet",
                message: "Finished recordings will appear here.",
                icon: "waveform"
            )
        } else if visibleRecords.isEmpty {
            CelesnityEmptyState(
                title: "No matching meetings",
                message: "Try another search or filter.",
                icon: "magnifyingglass"
            )
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(selectedFilter == .all ? "All meetings" : selectedFilter.title)
                            .font(CelesnityTypography.body(12).weight(.semibold))
                            .foregroundStyle(CelesnityTheme.secondary(for: colorScheme))
                        Spacer()
                        Text("\(visibleRecords.count) shown")
                            .font(CelesnityTypography.mono(10))
                            .foregroundStyle(CelesnityTheme.secondary(for: colorScheme).opacity(0.82))
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, 17)
                    .padding(.bottom, 3)

                    ForEach(visibleRecords) { meeting in
                        MeetingRow(
                            meeting: meeting,
                            isSelected: selectedMeetingID == meeting.id,
                            reduceMotion: reduceMotion,
                            onSelect: { selectedMeetingID = meeting.id },
                            onRename: { renameTarget = meeting },
                            onDelete: { deleteTarget = meeting }
                        )
                        .padding(.horizontal, 22)
                    }
                }
                .frame(maxWidth: 900, alignment: .leading)
                .padding(.bottom, 22)
            }
            .scrollIndicators(.hidden)
        }
    }

    private var libraryPlaceholder: some View {
        ZStack {
            CelesnityPalette.graphite
            VStack(alignment: .leading, spacing: 13) {
                Text("Meetings, with context.")
                    .font(CelesnityTypography.display(38))
                    .foregroundStyle(CelesnityPalette.ivory)
                Text("Select a conversation to read the note or verify the transcript.")
                    .font(CelesnityTypography.body(14))
                    .foregroundStyle(CelesnityPalette.ivory.opacity(0.62))
                    .frame(maxWidth: 340, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(42)
        }
    }

    private var deleteMessage: String {
        guard let deleteTarget else {
            return "This permanently removes the recording and any transcript or meeting note files."
        }
        let names = [deleteTarget.recordingURL, deleteTarget.transcriptURL, deleteTarget.meetingNoteURL]
            .compactMap { $0?.lastPathComponent }
            .joined(separator: ", ")
        return "This cannot be undone. Files to remove: \(names)."
    }

    private func count(_ status: MeetingStatus) -> Int {
        library.records.count { $0.status == status }
    }

    private func select(_ filter: MeetingFilter) {
        withAnimation(reduceMotion ? nil : CelesnityMotion.standard) {
            selectedFilter = filter
        }
    }

    private func refresh() {
        library.refresh(processingURL: engine.processingRecordingURL)
    }
}

private struct MeetingRow: View {
    let meeting: MeetingRecord
    let isSelected: Bool
    let reduceMotion: Bool
    let onSelect: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void
    @State private var isHovering = false
    @State private var isActionsPopoverPresented = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack(alignment: .topTrailing) {
            rowButton
            rowActionsButton
                .padding(.trailing, 13)
                .padding(.top, 13)
        }
        .onHover { isHovering = $0 }
        .animation(reduceMotion ? nil : CelesnityMotion.standard, value: isHovering)
        .contextMenu {
            Button("Rename", action: onRename)
            Button("Delete Permanently", role: .destructive, action: onDelete)
        }
    }

    private var rowButton: some View {
        Button(action: onSelect) {
            HStack(spacing: 14) {
                WaveformAccent(seed: meeting.displayName)
                    .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: 5) {
                    Text(meeting.displayName)
                        .font(CelesnityTypography.body(14).weight(.semibold))
                        .foregroundStyle(CelesnityTheme.primary(for: colorScheme))
                        .lineLimit(1)
                    HStack(spacing: 7) {
                        Text(meeting.modifiedAt.formatted(date: .abbreviated, time: .shortened))
                        Text("·")
                        Text(durationText(meeting.duration))
                    }
                    .font(CelesnityTypography.body(11))
                    .foregroundStyle(CelesnityTheme.secondary(for: colorScheme))
                    .fixedSize(horizontal: true, vertical: false)
                }

                HStack(spacing: 10) {
                    ArtifactMark(title: "Transcript", ready: meeting.hasTranscript)
                    ArtifactMark(title: "Note", ready: meeting.hasMeetingNote)
                    CelesnityStatusChip(status: meeting.status)
                }
                .fixedSize(horizontal: true, vertical: false)

                Spacer(minLength: 0)
            }
            .padding(.trailing, 46)
            .padding(.horizontal, 15)
            .padding(.vertical, 13)
            .background(
                isSelected ? selectedSurface : CelesnityTheme.rowSurface(for: colorScheme, isHovering: isHovering),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(isSelected ? selectionStroke : .clear, lineWidth: 1)
            }
            .scaleEffect(isHovering && !reduceMotion ? 1.006 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(true)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityLabel("\(meeting.displayName), \(statusText)")
    }

    private var statusText: String {
        CelesnityStatusStyle.style(for: meeting.status).title
    }

    private var selectedSurface: Color {
        colorScheme == .dark ? CelesnityPalette.graphiteSoft : CelesnityPalette.readingSurface
    }

    private var selectionStroke: Color {
        colorScheme == .dark ? CelesnityPalette.ivoryBright.opacity(0.78) : CelesnityPalette.graphite.opacity(0.64)
    }

    private var rowActionsButton: some View {
        Button {
            isActionsPopoverPresented.toggle()
        } label: {
            Image(systemName: "ellipsis")
                .font(.body.weight(.semibold))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(CelesnityTheme.secondary(for: colorScheme))
        .accessibilityLabel("Actions for \(meeting.displayName)")
        .popover(isPresented: $isActionsPopoverPresented, arrowEdge: .trailing) {
            VStack(alignment: .leading, spacing: 4) {
                Button {
                    isActionsPopoverPresented = false
                    onRename()
                } label: {
                    Label("Rename", systemImage: "pencil")
                }

                Divider()

                Button(role: .destructive) {
                    isActionsPopoverPresented = false
                    onDelete()
                } label: {
                    Label("Delete Permanently", systemImage: "trash")
                }
            }
            .buttonStyle(.plain)
            .labelStyle(.titleAndIcon)
            .font(CelesnityTypography.body(13).weight(.medium))
            .foregroundStyle(CelesnityTheme.primary(for: colorScheme))
            .padding(10)
            .frame(width: 224, alignment: .leading)
            .background(CelesnityTheme.controlSurface(for: colorScheme))
        }
    }

    private func durationText(_ duration: TimeInterval?) -> String {
        guard let duration, duration.isFinite, duration > 0 else { return "No duration" }
        let totalSeconds = Int(duration.rounded())
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return minutes >= 60
            ? String(format: "%d:%02d:%02d", minutes / 60, minutes % 60, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }
}

private struct ArtifactMark: View {
    let title: String
    let ready: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Label(title, systemImage: ready ? "checkmark" : "minus")
            .font(CelesnityTypography.body(10).weight(.semibold))
            .foregroundStyle(ready ? CelesnityTheme.primary(for: colorScheme) : CelesnityTheme.secondary(for: colorScheme).opacity(0.72))
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityLabel("\(title): \(ready ? "ready" : "missing")")
    }
}

private struct WaveformAccent: View {
    let seed: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<9, id: \.self) { index in
                Capsule()
                    .fill(index.isMultiple(of: 3) ? CelesnityPalette.clay : CelesnityTheme.primary(for: colorScheme).opacity(0.52))
                    .frame(width: 2.5, height: CGFloat(8 + ((seed.utf8.count + index * 7) % 16)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityHidden(true)
    }
}

struct CelesnityEmptyState: View {
    let title: String
    let message: String
    let icon: String
    var actionTitle: String?
    var action: (() -> Void)?
    @Environment(\.colorScheme) private var colorScheme

    init(title: String, message: String, icon: String, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        self.title = title
        self.message = message
        self.icon = icon
        self.actionTitle = actionTitle
        self.action = action
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(CelesnityPalette.clay)
            Text(title)
                .font(CelesnityTypography.display(24))
                .foregroundStyle(CelesnityTheme.primary(for: colorScheme))
            Text(message)
                .font(CelesnityTypography.body(13))
                .foregroundStyle(CelesnityTheme.secondary(for: colorScheme))
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .tint(CelesnityTheme.primary(for: colorScheme))
                    .foregroundStyle(CelesnityTheme.canvas(for: colorScheme))
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(34)
    }
}

private struct RenameMeetingSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var name: String
    let onRename: (String) -> Void

    init(initialName: String, onRename: @escaping (String) -> Void) {
        self.onRename = onRename
        _name = State(initialValue: initialName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename meeting")
                .font(CelesnityTypography.display(22))
                .foregroundStyle(CelesnityTheme.primary(for: colorScheme))
            TextField("Meeting name", text: $name)
                .textFieldStyle(.roundedBorder)
                .foregroundStyle(CelesnityTheme.primary(for: colorScheme))
                .tint(CelesnityPalette.clay)
                .onSubmit { submit() }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Rename") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
        }
        .padding(22)
        .frame(width: 380)
        .background(CelesnityTheme.canvas(for: colorScheme))
    }

    private var isValid: Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed != "." && trimmed != ".." && !trimmed.contains("/") && !trimmed.contains("\\")
    }

    private func submit() {
        guard isValid else { return }
        onRename(name)
        dismiss()
    }
}
