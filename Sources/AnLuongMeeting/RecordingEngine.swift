import Foundation
import AVFoundation
import AppKit
import Combine

enum TranscriptionState {
    case idle
    case notConfigured
    case processing(current: Int, total: Int)
    case generatingMeetingNote(current: Int, total: Int)
    case completed(transcriptURL: URL, meetingNoteURL: URL)
    case failed(String)
}

@MainActor
final class RecordingEngine: ObservableObject {

    @Published private(set) var isRecording = false
    @Published private(set) var isFinalizing = false
    @Published private(set) var isTranscribing = false
    @Published private(set) var elapsed: TimeInterval = 0
    /// True while startAsync is in flight. Starting takes seconds now (AEC
    /// init), and hotkey auto-repeat can fire toggle() many times in that
    /// window — without this guard each call spawns a full capture pipeline.
    private var isStarting = false
    /// Debounce: Carbon hotkeys fire repeatedly (~150ms) while held, which
    /// would stop a recording right after starting it.
    private var lastToggle = Date.distantPast
    @Published var systemMuted = false {
        didSet { writer?.systemMuted = systemMuted }
    }
    @Published var micMuted = false {
        didSet { writer?.micMuted = micMuted }
    }
    @Published private(set) var lastOutputURL: URL?
    @Published private(set) var processingRecordingURL: URL?
    /// Step-by-step log of the most recent transcribe/regenerate run, retained after it
    /// finishes so the meeting detail screen can show what happened (e.g. which topics the
    /// note-generation tree pipeline explored). Reset at the start of the next run.
    @Published private(set) var progressLog: [String] = []
    @Published private(set) var progressLogRecordingURL: URL?
    @Published private(set) var systemLevel: Float = 0
    @Published private(set) var micLevel: Float = 0
    /// True while a recording is running WITHOUT system audio (permission
    /// missing/stale or the selected source is unavailable). Surfaced in the
    /// popover and menu bar icon — a meeting recorded without the other side
    /// must never be a silent failure.
    @Published private(set) var systemAudioFailed = false
    @Published private(set) var systemAudioFailureMessage: String?
    @Published private(set) var systemAudioSources: [SystemAudioSourceOption] = [.all]
    @Published private(set) var isRefreshingSystemAudioSources = false
    @Published private(set) var systemAudioSourceError: String?
    @Published private(set) var selectedSystemAudioSource: SystemAudioSourceSelection
    @Published var geminiAPIKey: String {
        didSet {
            do {
                try apiKeyStore.save(geminiAPIKey)
            } catch {
                Log.write("could not save Gemini API key — \(error.localizedDescription)")
            }
        }
    }
    @Published private(set) var transcriptionState: TranscriptionState

    private let apiKeyStore = GeminiAPIKeyStore()
    private let transcriptionService = GeminiTranscriptionService()
    let memoryStore: MemoryStore
    @Published private(set) var pendingMemoryCount = 0
    @Published private(set) var isBackfillingMemory = false
    @Published private(set) var backfillProgress: (current: Int, total: Int) = (0, 0)
    /// Bumped whenever a memory/correction analysis pass finishes writing to disk — views
    /// showing a specific meeting's corrections observe this to know when to reload, since the
    /// analysis runs in a detached Task that outlives the regenerate/transcribe call that started it.
    @Published private(set) var lastMemoryRefreshToken = UUID()
    /// Bumped whenever a generation run finishes writing its `trace.json` sidecar — the
    /// traceability sidebar observes this to know when to reload for the current meeting.
    @Published private(set) var lastTraceRefreshToken = UUID()
    private var transcriptionTask: Task<Void, Never>?
    private var systemCapture: SystemAudioCapture?
    private var micCapture: MicrophoneCapture?
    private var writer: StereoWriter?
    private var startDate: Date?
    private var timer: Timer?
    private var sourceRefreshTask: Task<Void, Never>?
    private var sourceRefreshGeneration = UUID()

    init() {
        let savedKey = apiKeyStore.load() ?? ""
        let savedSource = SystemAudioSourceSelection.loadSaved()
        geminiAPIKey = savedKey
        selectedSystemAudioSource = savedSource
        memoryStore = MemoryStore(directory: Self.defaultRecordingsDirectory())
        if savedSource.kind != .all {
            systemAudioSources = [
                .all,
                .unavailable(for: savedSource)
            ]
        }
        transcriptionState = savedKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? .notConfigured
            : .idle
        pendingMemoryCount = memoryStore.load().pendingCount
    }

    private static func defaultRecordingsDirectory() -> URL {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Recordings", isDirectory: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return url
    }

    var recordingsDirectory: URL { Self.defaultRecordingsDirectory() }

    var canChangeSystemAudioSource: Bool {
        !isRecording && !isStarting && !isFinalizing && !isTranscribing
    }

    var isSelectedSystemAudioSourceUnavailable: Bool {
        selectedSystemAudioSource.kind != .all
            && !systemAudioSources.contains(where: {
                $0.isAvailable && $0.selection.matchesDiscovered(selectedSystemAudioSource)
            })
    }

    func refreshSystemAudioSources() {
        sourceRefreshTask?.cancel()
        let generation = UUID()
        sourceRefreshGeneration = generation
        isRefreshingSystemAudioSources = true
        systemAudioSourceError = nil

        sourceRefreshTask = Task { @MainActor [weak self] in
            do {
                let discovered = try await SystemAudioCapture.discoverSources()
                guard !Task.isCancelled, let self, self.sourceRefreshGeneration == generation else { return }

                var options = discovered
                if let matching = discovered.first(where: {
                    $0.selection.matchesDiscovered(self.selectedSystemAudioSource)
                }) {
                    if matching.selection != self.selectedSystemAudioSource {
                        self.selectedSystemAudioSource = matching.selection
                        self.selectedSystemAudioSource.save()
                    }
                } else if self.selectedSystemAudioSource.kind != .all {
                    options.insert(.unavailable(for: self.selectedSystemAudioSource), at: 1)
                }
                self.systemAudioSources = options
                self.systemAudioSourceError = nil
            } catch {
                guard !Task.isCancelled, let self, self.sourceRefreshGeneration == generation else { return }
                self.systemAudioSourceError = error.localizedDescription
                self.systemAudioSources = self.selectedSystemAudioSource.kind == .all
                    ? [.all]
                    : [.all, .unavailable(for: self.selectedSystemAudioSource)]
            }
            guard let self, self.sourceRefreshGeneration == generation else { return }
            self.isRefreshingSystemAudioSources = false
        }
    }

    func selectSystemAudioSource(_ source: SystemAudioSourceSelection) {
        guard canChangeSystemAudioSource else { return }
        selectedSystemAudioSource = source
        selectedSystemAudioSource.save()
    }

    func toggle() {
        guard Date().timeIntervalSince(lastToggle) > 1.0 else {
            Log.write("toggle ignored — debounced")
            return
        }
        lastToggle = Date()
        if isRecording {
            stop()
        } else {
            guard !isStarting, !isFinalizing, !isTranscribing else {
                Log.write("toggle ignored — recording or transcription is already in progress")
                return
            }
            Task {
                do { try await startAsync() } catch {
                    Log.write("failed to start — \(error)")
                    cleanup()
                }
            }
        }
    }

    func startAsync() async throws {
        guard !isRecording, !isStarting, !isFinalizing, !isTranscribing else { return }
        isStarting = true
        defer { isStarting = false }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        let meetingFolder = recordingsDirectory.appendingPathComponent(formatter.string(from: Date()), isDirectory: true)
        try FileManager.default.createDirectory(at: meetingFolder, withIntermediateDirectories: true)
        let url = meetingFolder.appendingPathComponent("recording.m4a")
        Log.write("starting recording → \(url.path)")

        let writer = try StereoWriter(outputURL: url)
        writer.systemMuted = systemMuted
        writer.micMuted = micMuted
        writer.start()
        self.writer = writer

        let mic = MicrophoneCapture()
        mic.onBuffer = { [weak writer, weak self] buffer, _ in
            writer?.appendMic(buffer: buffer)
            let peak = AudioLevel.peak(of: buffer)
            Task { @MainActor [weak self] in
                guard let self else { return }
                if peak > self.micLevel { self.micLevel = peak }
            }
        }
        try await mic.start()
        self.micCapture = mic

        let sys = SystemAudioCapture()
        sys.onBuffer = { [weak writer, weak self] buffer, _ in
            writer?.appendSystem(buffer: buffer)
            let peak = AudioLevel.peak(of: buffer)
            Task { @MainActor [weak self] in
                guard let self else { return }
                if peak > self.systemLevel { self.systemLevel = peak }
            }
        }
        do {
            try await sys.start(source: selectedSystemAudioSource)
            self.systemCapture = sys
        } catch {
            Log.write("system audio capture FAILED — \(error). Continuing with mic-only.")
            systemAudioFailed = true
            systemAudioFailureMessage = error.localizedDescription
            // Alert after start completes so the recording state isn't held
            // hostage by the modal.
            Task { @MainActor [weak self] in self?.alertSystemAudioFailure() }
        }

        let start = Date()
        startDate = start
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.elapsed = Date().timeIntervalSince(start)
                // Exponential decay so meters drop smoothly when levels fall.
                self.systemLevel *= 0.85
                self.micLevel *= 0.85
            }
        }
        lastOutputURL = url
        isRecording = true
    }

    func stop() {
        guard isRecording, !isFinalizing else { return }
        isFinalizing = true

        let sys = systemCapture
        let mic = micCapture
        let activeWriter = writer

        Task {
            await sys?.stop()
        }
        // AUVoiceIO teardown can block for a long time. Keep mic stop off the
        // main thread and never let the writer finalization wait on it —
        // otherwise the UI freezes and the m4a never gets its moov atom.
        Task.detached {
            guard let mic else { return }
            Log.write("stopping mic engine (background)")
            mic.stop()
        }

        guard let activeWriter else {
            transcriptionState = .failed("Recording writer was unavailable.")
            cleanup()
            return
        }

        activeWriter.finish { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }

                switch result {
                case .success(let url):
                    self.cleanup()
                    self.processingRecordingURL = url
                    self.notifyLibraryChanged()
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                    self.startTranscription(for: url)
                case .failure(let error):
                    self.transcriptionState = .failed(
                        "Recording finalization failed: \(error.localizedDescription)"
                    )
                    self.processingRecordingURL = nil
                    self.cleanup()
                    self.notifyLibraryChanged()
                }
            }
        }
    }

    private func startTranscription(for recordingURL: URL) {
        let key = geminiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            transcriptionState = .notConfigured
            isTranscribing = false
            processingRecordingURL = nil
            notifyLibraryChanged()
            return
        }

        transcriptionTask?.cancel()
        isTranscribing = true
        transcriptionState = .processing(current: 0, total: 0)
        beginProgressLog(for: recordingURL)
        let service = transcriptionService

        let memory = memoryStore.load()
        let memoryContext = memory.renderForPrompt()
        let glossaryCorrections = memory.glossaryCorrectionPairs()
        let recorder = LLMTraceRecorder()
        transcriptionTask = Task { @MainActor [weak self] in
            var currentRecordingURL = recordingURL
            do {
                let result = try await service.transcribe(
                    recordingURL: recordingURL,
                    apiKey: key,
                    memoryContext: memoryContext,
                    glossaryCorrections: glossaryCorrections,
                    progress: { [weak self] progress in
                        Task { @MainActor in
                            guard let self else { return }
                            self.appendProgressLog(progress)
                            switch progress.stage {
                            case .segment:
                                self.transcriptionState = .processing(
                                    current: progress.currentSegment,
                                    total: progress.totalSegments
                                )
                            case .meetingNote:
                                self.transcriptionState = .generatingMeetingNote(
                                    current: progress.currentSegment,
                                    total: progress.totalSegments
                                )
                            }
                        }
                    },
                    trace: recorder.asTraceFunction()
                )
                guard !Task.isCancelled, let self else { return }
                let renamed = self.autoRenameFromNoteTitle(
                    recordingURL: currentRecordingURL,
                    transcriptURL: result.transcriptURL,
                    meetingNoteURL: result.meetingNoteURL
                )
                currentRecordingURL = renamed.recordingURL
                if currentRecordingURL != recordingURL { self.progressLogRecordingURL = currentRecordingURL }
                self.transcriptionState = .completed(
                    transcriptURL: renamed.transcriptURL,
                    meetingNoteURL: renamed.meetingNoteURL
                )
                self.refreshMemorySuggestions(transcriptURL: renamed.transcriptURL, meetingNoteURL: renamed.meetingNoteURL, apiKey: key)
                self.isTranscribing = false
                self.transcriptionTask = nil
                self.processingRecordingURL = nil
                self.notifyLibraryChanged()
            } catch is CancellationError {
                self?.transcriptionState = .idle
                self?.isTranscribing = false
                self?.transcriptionTask = nil
                self?.processingRecordingURL = nil
                self?.notifyLibraryChanged()
            } catch {
                self?.transcriptionState = .failed(error.localizedDescription)
                self?.isTranscribing = false
                self?.transcriptionTask = nil
                self?.processingRecordingURL = nil
                self?.notifyLibraryChanged()
                Log.write("Gemini transcription or meeting note failed — \(error.localizedDescription)")
            }
            try? LLMTraceStore(directory: currentRecordingURL.deletingLastPathComponent()).save(await recorder.entries)
            self?.lastTraceRefreshToken = UUID()
        }
    }

    private func notifyLibraryChanged() {
        NotificationCenter.default.post(name: .anluongLibraryDidChange, object: nil)
    }

    private func beginProgressLog(for recordingURL: URL) {
        progressLog = []
        progressLogRecordingURL = recordingURL
    }

    private func appendProgressLog(_ progress: TranscriptionProgress) {
        let prefix = progress.stage == .segment ? "Transcript" : "Note"
        let text = progress.message.isEmpty
            ? "\(prefix): step \(progress.currentSegment) of \(progress.totalSegments)"
            : "\(prefix): \(progress.message)"
        progressLog.append(text)
    }

    func refreshPendingMemoryCount() {
        pendingMemoryCount = memoryStore.load().pendingCount
    }

    /// Scans existing meetings that already have both a transcript and a note, and runs the
    /// memory-suggestion pass over each one — lets the glossary catch up on meetings recorded
    /// before this feature existed, instead of only learning from new recordings.
    func backfillMemoryFromExistingMeetings() {
        guard !isBackfillingMemory else { return }
        let key = geminiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        guard let records = try? MeetingLibraryIndex.scan(directory: recordingsDirectory, processingURL: nil) else { return }
        let eligible = records.filter { $0.hasTranscript && $0.hasMeetingNote }
        guard !eligible.isEmpty else { return }

        isBackfillingMemory = true
        backfillProgress = (0, eligible.count)
        let store = memoryStore
        let service = transcriptionService

        Task {
            var memory = store.load()
            for (index, record) in eligible.enumerated() {
                if let transcriptURL = record.transcriptURL,
                   let noteURL = record.meetingNoteURL,
                   let transcript = try? String(contentsOf: transcriptURL, encoding: .utf8),
                   let note = try? String(contentsOf: noteURL, encoding: .utf8),
                   let draft = try? await service.suggestMemoryUpdates(
                       transcript: transcript,
                       note: note,
                       currentMemory: memory.renderForPrompt(),
                       apiKey: key
                   ) {
                    memory.merge(draft: draft)
                    Self.mergePendingIdentityMerges(draft.identityMerges, into: &memory)
                    Self.saveCorrections(draft.corrections, noteText: note, forNoteAt: noteURL)
                }
                await MainActor.run { self.backfillProgress = (index + 1, eligible.count) }
            }
            try? store.save(memory)
            await MainActor.run {
                self.isBackfillingMemory = false
                self.refreshPendingMemoryCount()
                self.lastMemoryRefreshToken = UUID()
            }
        }
    }

    private func refreshMemorySuggestions(transcriptURL: URL, meetingNoteURL: URL, apiKey: String) {
        let store = memoryStore
        let service = transcriptionService
        Task {
            guard let transcript = try? String(contentsOf: transcriptURL, encoding: .utf8),
                  let note = try? String(contentsOf: meetingNoteURL, encoding: .utf8) else { return }
            var memory = store.load()
            guard let draft = try? await service.suggestMemoryUpdates(
                transcript: transcript,
                note: note,
                currentMemory: memory.renderForPrompt(),
                apiKey: apiKey
            ) else { return }
            memory.merge(draft: draft)
            Self.mergePendingIdentityMerges(draft.identityMerges, into: &memory)
            try? store.save(memory)
            Self.saveCorrections(draft.corrections, noteText: note, forNoteAt: meetingNoteURL)
            await MainActor.run {
                self.refreshPendingMemoryCount()
                self.lastMemoryRefreshToken = UUID()
            }
        }
    }

    private static func mergePendingIdentityMerges(_ merges: [IdentityMergeSuggestion], into memory: inout MemoryData) {
        let existingNameSets = Set(memory.pendingMerges.map { Set($0.names.map { $0.lowercased() }) })
        for merge in merges where !existingNameSets.contains(Set(merge.names.map { $0.lowercased() })) {
            memory.pendingMerges.append(merge)
        }
    }

    /// Merges freshly-found corrections with the existing sidecar rather than overwriting it:
    /// a previously pending correction is dropped only when its wrongText no longer literally
    /// appears in the current note (evidence it was actually fixed), not just because this
    /// particular Gemini pass didn't re-flag it — an LLM response can be incomplete, and
    /// trusting it as the sole source of truth would silently drop real unfixed issues.
    private static func saveCorrections(_ corrections: [NoteCorrection], noteText: String, forNoteAt noteURL: URL) {
        let store = NoteCorrectionStore(directory: noteURL.deletingLastPathComponent())
        let stillRelevant = store.load().filter { $0.status != .pending || noteText.contains($0.wrongText) }
        let existingWrongTexts = Set(stillRelevant.map { $0.wrongText.lowercased() })
        let merged = stillRelevant + corrections.filter { !existingWrongTexts.contains($0.wrongText.lowercased()) }
        try? store.save(merged)
    }

    /// If this meeting still has its auto-generated `yyyy-MM-dd_HHmmss` folder name, renames
    /// it to match the title Gemini gave the note — so meetings show up in the library named
    /// for what they're actually about instead of just when they were recorded. Never touches
    /// a folder that's already been renamed (by this or by the user), since that's the only
    /// reliable signal available for "don't clobber a name someone chose on purpose."
    private func autoRenameFromNoteTitle(
        recordingURL: URL, transcriptURL: URL, meetingNoteURL: URL
    ) -> (recordingURL: URL, transcriptURL: URL, meetingNoteURL: URL) {
        let unchanged = (recordingURL, transcriptURL, meetingNoteURL)
        let folder = recordingURL.deletingLastPathComponent()
        guard Self.looksLikeDefaultMeetingName(folder.lastPathComponent),
              let note = try? String(contentsOf: meetingNoteURL, encoding: .utf8),
              let title = Self.titleFromNote(note) else {
            return unchanged
        }
        let sanitized = Self.sanitizedFolderName(from: title)
        guard !sanitized.isEmpty, sanitized != folder.lastPathComponent else { return unchanged }

        let destination = Self.uniqueFolder(named: sanitized, in: recordingsDirectory)
        do {
            try FileManager.default.moveItem(at: folder, to: destination)
            return (
                destination.appendingPathComponent(recordingURL.lastPathComponent),
                destination.appendingPathComponent(transcriptURL.lastPathComponent),
                destination.appendingPathComponent(meetingNoteURL.lastPathComponent)
            )
        } catch {
            Log.write("auto-rename meeting folder failed — \(error.localizedDescription)")
            return unchanged
        }
    }

    private static func looksLikeDefaultMeetingName(_ name: String) -> Bool {
        name.range(of: #"^\d{4}-\d{2}-\d{2}_\d{6}$"#, options: .regularExpression) != nil
    }

    /// The generated note's title is always the first line, as `# Title` (see
    /// `assembleFinalNote`). Falls back to nil rather than guessing if that's ever not so.
    private static func titleFromNote(_ note: String) -> String? {
        guard let firstLine = note.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first else {
            return nil
        }
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("# ") else { return nil }
        return String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
    }

    private static func sanitizedFolderName(from title: String) -> String {
        let cleaned = title
            .components(separatedBy: CharacterSet(charactersIn: "/\\:"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(cleaned.prefix(120))
    }

    private static func uniqueFolder(named name: String, in directory: URL) -> URL {
        var candidate = directory.appendingPathComponent(name, isDirectory: true)
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(name) (\(suffix))", isDirectory: true)
            suffix += 1
        }
        return candidate
    }

    private func alertSystemAudioFailure() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "System audio is NOT being recorded"
        alert.informativeText = """
        This recording will contain the microphone only.

        \(systemAudioFailureMessage ?? "The selected system-audio source could not be started.")

        The Screen Recording permission is missing or stale (common after \
        upgrading AnLuong Meeting). Open System Settings, toggle AnLuong Meeting off and \
        back on under Screen Recording, then fully quit and relaunch.
        """
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Continue Mic-Only")
        if alert.runModal() == .alertFirstButtonReturn {
            ScreenRecordingPermission.openSettings()
        }
    }

    private func cleanup() {
        timer?.invalidate()
        timer = nil
        systemCapture = nil
        micCapture = nil
        writer = nil
        startDate = nil
        elapsed = 0
        systemLevel = 0
        micLevel = 0
        isRecording = false
        isFinalizing = false
        systemAudioFailed = false
        systemAudioFailureMessage = nil
    }

    // MARK: - On-demand regeneration

    /// Regenerate transcript, meeting note, or both for an existing recording.
    func regenerate(meeting: MeetingRecord, mode: RegenerationMode) {
        let key = geminiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            transcriptionState = .notConfigured
            return
        }
        guard !isTranscribing, !isRecording else {
            Log.write("regenerate ignored — already busy")
            return
        }

        transcriptionTask?.cancel()
        isTranscribing = true
        processingRecordingURL = meeting.recordingURL
        beginProgressLog(for: meeting.recordingURL)
        notifyLibraryChanged()

        let service = transcriptionService
        let recordingURL = meeting.recordingURL
        let memory = memoryStore.load()
        let memoryContext = memory.renderForPrompt()
        let glossaryCorrections = memory.glossaryCorrectionPairs()
        let recorder = LLMTraceRecorder()

        transcriptionTask = Task { @MainActor [weak self] in
            var currentRecordingURL = recordingURL
            do {
                switch mode {
                case .transcriptOnly:
                    self?.transcriptionState = .processing(current: 0, total: 0)
                    let transcriptURL = try await service.transcribeOnly(
                        recordingURL: recordingURL,
                        apiKey: key,
                        memoryContext: memoryContext,
                        glossaryCorrections: glossaryCorrections,
                        progress: { [weak self] progress in
                            Task { @MainActor in
                                guard let self else { return }
                                self.appendProgressLog(progress)
                                self.transcriptionState = .processing(
                                    current: progress.currentSegment,
                                    total: progress.totalSegments
                                )
                            }
                        },
                        trace: recorder.asTraceFunction()
                    )
                    guard !Task.isCancelled else { return }
                    self?.transcriptionState = .completed(
                        transcriptURL: transcriptURL,
                        meetingNoteURL: meeting.meetingNoteURL ?? transcriptURL
                    )

                case .noteOnly:
                    self?.transcriptionState = .generatingMeetingNote(current: 0, total: 0)
                    guard let transcriptURL = meeting.transcriptURL else {
                        throw GeminiTranscriptionError.emptyTranscript(0)
                    }
                    let noteURL = try await service.regenerateNote(
                        transcriptURL: transcriptURL,
                        recordingURL: recordingURL,
                        apiKey: key,
                        memoryContext: memoryContext,
                        glossaryCorrections: glossaryCorrections,
                        progress: { [weak self] progress in
                            Task { @MainActor in
                                guard let self else { return }
                                self.appendProgressLog(progress)
                                self.transcriptionState = .generatingMeetingNote(
                                    current: progress.currentSegment,
                                    total: progress.totalSegments
                                )
                            }
                        },
                        trace: recorder.asTraceFunction()
                    )
                    guard !Task.isCancelled, let self else { return }
                    let renamed = self.autoRenameFromNoteTitle(
                        recordingURL: currentRecordingURL,
                        transcriptURL: transcriptURL,
                        meetingNoteURL: noteURL
                    )
                    currentRecordingURL = renamed.recordingURL
                    if currentRecordingURL != recordingURL { self.progressLogRecordingURL = currentRecordingURL }
                    self.transcriptionState = .completed(
                        transcriptURL: renamed.transcriptURL,
                        meetingNoteURL: renamed.meetingNoteURL
                    )
                    self.refreshMemorySuggestions(transcriptURL: renamed.transcriptURL, meetingNoteURL: renamed.meetingNoteURL, apiKey: key)

                case .both:
                    self?.transcriptionState = .processing(current: 0, total: 0)
                    let result = try await service.transcribe(
                        recordingURL: recordingURL,
                        apiKey: key,
                        memoryContext: memoryContext,
                        glossaryCorrections: glossaryCorrections,
                        progress: { [weak self] progress in
                            Task { @MainActor in
                                guard let self else { return }
                                self.appendProgressLog(progress)
                                switch progress.stage {
                                case .segment:
                                    self.transcriptionState = .processing(
                                        current: progress.currentSegment,
                                        total: progress.totalSegments
                                    )
                                case .meetingNote:
                                    self.transcriptionState = .generatingMeetingNote(
                                    current: progress.currentSegment,
                                    total: progress.totalSegments
                                )
                                }
                            }
                        },
                        trace: recorder.asTraceFunction()
                    )
                    guard !Task.isCancelled, let self else { return }
                    let renamed = self.autoRenameFromNoteTitle(
                        recordingURL: currentRecordingURL,
                        transcriptURL: result.transcriptURL,
                        meetingNoteURL: result.meetingNoteURL
                    )
                    currentRecordingURL = renamed.recordingURL
                    if currentRecordingURL != recordingURL { self.progressLogRecordingURL = currentRecordingURL }
                    self.transcriptionState = .completed(
                        transcriptURL: renamed.transcriptURL,
                        meetingNoteURL: renamed.meetingNoteURL
                    )
                    self.refreshMemorySuggestions(transcriptURL: renamed.transcriptURL, meetingNoteURL: renamed.meetingNoteURL, apiKey: key)
                }

                self?.isTranscribing = false
                self?.transcriptionTask = nil
                self?.processingRecordingURL = nil
                self?.notifyLibraryChanged()
            } catch is CancellationError {
                self?.transcriptionState = .idle
                self?.isTranscribing = false
                self?.transcriptionTask = nil
                self?.processingRecordingURL = nil
                self?.notifyLibraryChanged()
            } catch {
                self?.transcriptionState = .failed(error.localizedDescription)
                self?.isTranscribing = false
                self?.transcriptionTask = nil
                self?.processingRecordingURL = nil
                self?.notifyLibraryChanged()
                Log.write("regeneration failed — \(error.localizedDescription)")
            }
            try? LLMTraceStore(directory: currentRecordingURL.deletingLastPathComponent()).save(await recorder.entries)
            self?.lastTraceRefreshToken = UUID()
        }
    }
}
