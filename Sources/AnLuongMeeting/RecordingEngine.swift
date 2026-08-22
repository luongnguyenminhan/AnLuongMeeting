import Foundation
import AVFoundation
import AppKit
import Combine

enum TranscriptionState {
    case idle
    case notConfigured
    case processing(current: Int, total: Int)
    case generatingMeetingNote
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
        if savedSource.kind != .all {
            systemAudioSources = [
                .all,
                .unavailable(for: savedSource)
            ]
        }
        transcriptionState = savedKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? .notConfigured
            : .idle
    }

    var recordingsDirectory: URL {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Recordings", isDirectory: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return url
    }

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
        let filename = "\(formatter.string(from: Date())).m4a"
        let url = recordingsDirectory.appendingPathComponent(filename)
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
        let service = transcriptionService

        transcriptionTask = Task { @MainActor [weak self] in
            do {
                let result = try await service.transcribe(
                    recordingURL: recordingURL,
                    apiKey: key,
                    progress: { [weak self] progress in
                        Task { @MainActor in
                            guard let self else { return }
                            switch progress.stage {
                            case .segment:
                                self.transcriptionState = .processing(
                                    current: progress.currentSegment,
                                    total: progress.totalSegments
                                )
                            case .meetingNote:
                                self.transcriptionState = .generatingMeetingNote
                            }
                        }
                    }
                )
                guard !Task.isCancelled else { return }
                self?.transcriptionState = .completed(
                    transcriptURL: result.transcriptURL,
                    meetingNoteURL: result.meetingNoteURL
                )
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
                Log.write("Gemini transcription or meeting note failed — \(error.localizedDescription)")
            }
        }
    }

    private func notifyLibraryChanged() {
        NotificationCenter.default.post(name: .anluongLibraryDidChange, object: nil)
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
        notifyLibraryChanged()

        let service = transcriptionService
        let recordingURL = meeting.recordingURL

        transcriptionTask = Task { @MainActor [weak self] in
            do {
                switch mode {
                case .transcriptOnly:
                    self?.transcriptionState = .processing(current: 0, total: 0)
                    let transcriptURL = try await service.transcribeOnly(
                        recordingURL: recordingURL,
                        apiKey: key,
                        progress: { [weak self] progress in
                            Task { @MainActor in
                                guard let self else { return }
                                self.transcriptionState = .processing(
                                    current: progress.currentSegment,
                                    total: progress.totalSegments
                                )
                            }
                        }
                    )
                    guard !Task.isCancelled else { return }
                    self?.transcriptionState = .completed(
                        transcriptURL: transcriptURL,
                        meetingNoteURL: meeting.meetingNoteURL ?? transcriptURL
                    )

                case .noteOnly:
                    self?.transcriptionState = .generatingMeetingNote
                    guard let transcriptURL = meeting.transcriptURL else {
                        throw GeminiTranscriptionError.emptyTranscript(0)
                    }
                    let noteURL = try await service.regenerateNote(
                        transcriptURL: transcriptURL,
                        recordingURL: recordingURL,
                        apiKey: key
                    )
                    guard !Task.isCancelled else { return }
                    self?.transcriptionState = .completed(
                        transcriptURL: transcriptURL,
                        meetingNoteURL: noteURL
                    )

                case .both:
                    self?.transcriptionState = .processing(current: 0, total: 0)
                    let result = try await service.transcribe(
                        recordingURL: recordingURL,
                        apiKey: key,
                        progress: { [weak self] progress in
                            Task { @MainActor in
                                guard let self else { return }
                                switch progress.stage {
                                case .segment:
                                    self.transcriptionState = .processing(
                                        current: progress.currentSegment,
                                        total: progress.totalSegments
                                    )
                                case .meetingNote:
                                    self.transcriptionState = .generatingMeetingNote
                                }
                            }
                        }
                    )
                    guard !Task.isCancelled else { return }
                    self?.transcriptionState = .completed(
                        transcriptURL: result.transcriptURL,
                        meetingNoteURL: result.meetingNoteURL
                    )
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
        }
    }
}
