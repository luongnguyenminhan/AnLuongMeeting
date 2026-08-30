import Foundation
import Combine
import AnLuongMeetingCore

enum IOSProcessingState: Equatable {
    case idle
    case processing(mode: GeminiRegenerationMode, current: Int, total: Int)
    case generatingMeetingNote(mode: GeminiRegenerationMode)
    case completed(URL)
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .processing, .generatingMeetingNote: return true
        case .idle, .completed, .failed: return false
        }
    }
}

@MainActor
final class IOSPendingWorkCoordinator: ObservableObject {
    @Published private(set) var pendingURLs: [URL] = []
    @Published private(set) var lastCompletedURL: URL?
    @Published private(set) var errorMessage: String?
    @Published private(set) var processingState: IOSProcessingState = .idle
    @Published private(set) var activeRecordingURL: URL?
    @Published private(set) var progressMessage = ""
    @Published private(set) var queuePosition = 0
    @Published private(set) var queueTotal = 0

    private let storage: any MeetingStorage
    private let keyStore: any APIKeyStore
    private let notifications: any IOSNotificationSink
    private let service: any MeetingTranscriptionService
    let memoryStore: MemoryStore
    @Published private(set) var pendingMemoryCount = 0
    @Published private(set) var isBackfillingMemory = false
    @Published private(set) var backfillProgress: (current: Int, total: Int) = (0, 0)
    private var processingTask: Task<Void, Never>?
    private var lastRecord: MeetingRecord?
    private var lastMode: GeminiRegenerationMode?

    init(
        storage: any MeetingStorage = IOSMeetingStorage(),
        keyStore: any APIKeyStore = IOSAPIKeyStore(),
        notificationCoordinator: (any IOSNotificationSink)? = nil,
        transcriptionService: any MeetingTranscriptionService = GeminiTranscriptionService(),
        memoryStore: MemoryStore = MemoryStore(directory: IOSMeetingStorage().recordingsDirectory)
    ) {
        self.storage = storage
        self.keyStore = keyStore
        self.notifications = notificationCoordinator ?? IOSNotificationCoordinator.shared
        self.service = transcriptionService
        self.memoryStore = memoryStore
        self.pendingMemoryCount = memoryStore.load().pendingCount
    }

    var shouldShowStatusCard: Bool {
        processingState.isBusy || activeRecordingURL != nil || !pendingURLs.isEmpty || processingState.isFailure || errorMessage != nil
    }

    func enqueue(recordingURL: URL) {
        if !pendingURLs.contains(recordingURL) {
            pendingURLs.append(recordingURL)
        }
        queueTotal = max(queueTotal, pendingURLs.count)
    }

    func clearError() {
        errorMessage = nil
        if case .failed = processingState, activeRecordingURL == nil {
            processingState = .idle
            progressMessage = ""
        }
    }

    func regenerate(record: MeetingRecord, mode: GeminiRegenerationMode) {
        guard !processingState.isBusy, processingTask == nil else { return }
        guard let key = keyStore.load()?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            failWithoutNotification("Add a Gemini API key in Settings to regenerate this meeting.")
            return
        }
        lastRecord = record
        lastMode = mode
        errorMessage = nil
        activeRecordingURL = record.recordingURL
        enqueue(recordingURL: record.recordingURL)
        queuePosition = 1
        queueTotal = 1
        processingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.run(record: record, mode: mode, apiKey: key)
            self.processingTask = nil
        }
    }

    func cancelProcessing() {
        processingTask?.cancel()
        processingTask = nil
        processingState = .idle
        progressMessage = "Processing cancelled."
        queuePosition = 0
        queueTotal = pendingURLs.count
        activeRecordingURL = nil
    }

    func retryLastOperation() {
        guard let record = lastRecord, let mode = lastMode else { return }
        regenerate(record: record, mode: mode)
    }

    func resumePendingWork() async {
        guard processingTask == nil, !processingState.isBusy else { return }
        guard let key = keyStore.load()?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            errorMessage = "Add a Gemini API key in Settings to process recordings."
            progressMessage = errorMessage ?? ""
            return
        }

        processingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.processPendingWork(apiKey: key)
        }
        await processingTask?.value
        processingTask = nil
    }

    private func processPendingWork(apiKey: String) async {
        let records = (try? storage.scan(processingURL: activeRecordingURL)) ?? []
        let candidates = records.filter { $0.status != .ready }
        for record in candidates {
            enqueue(recordingURL: record.recordingURL)
        }

        let queued = pendingURLs
        queueTotal = queued.count
        for (index, url) in queued.enumerated() {
            guard !Task.isCancelled else { break }
            guard FileManager.default.fileExists(atPath: url.path) else {
                pendingURLs.removeAll { $0 == url }
                continue
            }
            guard let record = records.first(where: { $0.recordingURL == url }) else { continue }
            queuePosition = index + 1
            let mode: GeminiRegenerationMode
            if record.transcriptURL == nil {
                mode = .both
            } else if record.meetingNoteURL == nil {
                mode = .noteOnly
            } else {
                mode = .both
            }
            await run(record: record, mode: mode, apiKey: apiKey)
            if case .failed = processingState { break }
        }
        if !processingState.isBusy {
            queuePosition = 0
            if pendingURLs.isEmpty { queueTotal = 0 }
        }
    }

    private func run(record: MeetingRecord, mode: GeminiRegenerationMode, apiKey: String) async {
        lastRecord = record
        lastMode = mode
        activeRecordingURL = record.recordingURL
        errorMessage = nil
        let memoryContext = memoryStore.load().renderForPrompt()
        do {
            switch mode {
            case .transcriptOnly:
                processingState = .processing(mode: mode, current: 0, total: 0)
                progressMessage = "Preparing the recording…"
                _ = try await service.transcribeOnly(
                    recordingURL: record.recordingURL,
                    apiKey: apiKey,
                    memoryContext: memoryContext,
                    progress: progressHandler(for: mode)
                )
                notifications.notifyTranscriptReady()
            case .noteOnly:
                processingState = .generatingMeetingNote(mode: mode)
                progressMessage = "Preparing the meeting note…"
                guard let transcriptURL = record.transcriptURL else {
                    throw GeminiTranscriptionError.emptyTranscript(0)
                }
                let noteURL = try await service.regenerateNote(
                    transcriptURL: transcriptURL,
                    recordingURL: record.recordingURL,
                    apiKey: apiKey,
                    memoryContext: memoryContext,
                    progress: progressHandler(for: mode)
                )
                await refreshMemory(transcriptURL: transcriptURL, meetingNoteURL: noteURL, apiKey: apiKey)
            case .both:
                processingState = .processing(mode: mode, current: 0, total: 0)
                progressMessage = "Preparing the recording…"
                let result = try await service.transcribe(
                    recordingURL: record.recordingURL,
                    apiKey: apiKey,
                    memoryContext: memoryContext,
                    progress: progressHandler(for: mode)
                )
                await refreshMemory(transcriptURL: result.transcriptURL, meetingNoteURL: result.meetingNoteURL, apiKey: apiKey)
            }
            guard !Task.isCancelled else { return }
            processingState = .completed(record.recordingURL)
            progressMessage = "Meeting processing complete."
            lastCompletedURL = record.recordingURL
            pendingURLs.removeAll { $0 == record.recordingURL }
            activeRecordingURL = nil
        } catch is CancellationError {
            processingState = .idle
            progressMessage = "Processing cancelled."
            activeRecordingURL = nil
        } catch {
            processingState = .failed(error.localizedDescription)
            progressMessage = error.localizedDescription
            errorMessage = error.localizedDescription
            notifications.notifyProcessingFailed()
        }
    }

    private func refreshMemory(transcriptURL: URL, meetingNoteURL: URL, apiKey: String) async {
        guard let transcript = try? String(contentsOf: transcriptURL, encoding: .utf8),
              let note = try? String(contentsOf: meetingNoteURL, encoding: .utf8) else { return }
        var memory = memoryStore.load()
        guard let draft = try? await service.suggestMemoryUpdates(
            transcript: transcript,
            note: note,
            currentMemory: memory.renderForPrompt(),
            apiKey: apiKey
        ) else { return }
        memory.merge(draft: draft)
        Self.mergePendingIdentityMerges(draft.identityMerges, into: &memory)
        try? memoryStore.save(memory)
        Self.saveCorrections(draft.corrections, noteText: note, forNoteAt: meetingNoteURL)
        pendingMemoryCount = memory.pendingCount
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

    /// Scans existing meetings that already have both a transcript and a note, and runs the
    /// memory-suggestion pass over each one — lets the glossary catch up on meetings recorded
    /// before this feature existed, instead of only learning from new recordings.
    func backfillMemoryFromExistingMeetings() {
        guard !isBackfillingMemory else { return }
        guard let key = keyStore.load()?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else { return }
        guard let records = try? storage.scan(processingURL: activeRecordingURL) else { return }
        let eligible = records.filter { $0.hasTranscript && $0.hasMeetingNote }
        guard !eligible.isEmpty else { return }

        isBackfillingMemory = true
        backfillProgress = (0, eligible.count)

        Task { [weak self] in
            guard let self else { return }
            var memory = self.memoryStore.load()
            for (index, record) in eligible.enumerated() {
                if let transcriptURL = record.transcriptURL,
                   let noteURL = record.meetingNoteURL,
                   let transcript = try? String(contentsOf: transcriptURL, encoding: .utf8),
                   let note = try? String(contentsOf: noteURL, encoding: .utf8),
                   let draft = try? await self.service.suggestMemoryUpdates(
                       transcript: transcript,
                       note: note,
                       currentMemory: memory.renderForPrompt(),
                       apiKey: key
                   ) {
                    memory.merge(draft: draft)
                    Self.mergePendingIdentityMerges(draft.identityMerges, into: &memory)
                    Self.saveCorrections(draft.corrections, noteText: note, forNoteAt: noteURL)
                }
                self.backfillProgress = (index + 1, eligible.count)
            }
            try? self.memoryStore.save(memory)
            self.pendingMemoryCount = memory.pendingCount
            self.isBackfillingMemory = false
        }
    }

    private func failWithoutNotification(_ message: String) {
        processingState = .failed(message)
        progressMessage = message
        errorMessage = message
        activeRecordingURL = nil
    }

    private func progressHandler(for mode: GeminiRegenerationMode) -> @Sendable (TranscriptionProgress) -> Void {
        { [weak self] progress in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.progressMessage = progress.message
                if progress.message.hasPrefix("Transcript saved") {
                    self.notifications.notifyTranscriptReady()
                } else if progress.message == "Meeting note saved." {
                    self.notifications.notifyMeetingNoteReady()
                }
                switch progress.stage {
                case .segment:
                    self.processingState = .processing(
                        mode: mode,
                        current: progress.currentSegment,
                        total: progress.totalSegments
                    )
                case .meetingNote:
                    self.processingState = .generatingMeetingNote(mode: mode)
                }
            }
        }
    }
}

private extension IOSProcessingState {
    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}
