import Foundation
import AVFoundation
import Combine
import AnLuongMeetingCore

enum IOSRecordingState: Equatable {
    case idle
    case requestingPermission
    case recording
    case interrupted
    case finalizing
    case processing
    case failed(String)
}

@MainActor
final class IOSRecordingCoordinator: ObservableObject {
    @Published private(set) var state: IOSRecordingState = .idle
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var micLevel: Float = 0
    @Published private(set) var currentRecordingURL: URL?
    @Published private(set) var lastFinishedURL: URL?
    @Published private(set) var lastError: String?

    let storage: IOSMeetingStorage
    private let audioSession: IOSAudioSessionController
    private let recorder = IOSMicrophoneRecorder()
    private var writer: IOSAudioFileWriter?
    private var startedAt: Date?
    private var timer: Timer?

    init(storage: IOSMeetingStorage = IOSMeetingStorage(), audioSession: IOSAudioSessionController? = nil) {
        self.storage = storage
        self.audioSession = audioSession ?? IOSAudioSessionController()
        self.audioSession.onInterruption = { [weak self] interruption in
            self?.receive(interruption: interruption)
        }
        recorder.onLevel = { [weak self] level in
            Task { @MainActor in self?.micLevel = level }
        }
    }

    func start() async {
        guard state == .idle || state.isFailure else { return }
        state = .requestingPermission
        guard await audioSession.requestPermission() else {
            fail("Microphone permission is required to record a meeting.")
            return
        }
        do {
            try audioSession.activate()
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd_HHmmss"
            let meetingFolder = storage.recordingsDirectory.appendingPathComponent(formatter.string(from: Date()), isDirectory: true)
            try FileManager.default.createDirectory(at: meetingFolder, withIntermediateDirectories: true)
            let url = meetingFolder.appendingPathComponent("recording.m4a")
            let writer = IOSAudioFileWriter(outputURL: url)
            try recorder.start(writer: writer)
            self.writer = writer
            currentRecordingURL = url
            startedAt = Date()
            elapsed = 0
            state = .recording
            startTimer()
        } catch {
            audioSession.deactivate()
            fail("Could not start microphone recording: \(error.localizedDescription)")
        }
    }

    func stop() {
        guard state == .recording || state == .interrupted else { return }
        state = .finalizing
        timer?.invalidate()
        timer = nil
        recorder.stop()
        audioSession.deactivate()
        var finishedURL: URL?
        if let writer {
            finishedURL = writer.finish()
            currentRecordingURL = finishedURL
        }
        self.writer = nil
        lastFinishedURL = finishedURL
        state = currentRecordingURL == nil ? .idle : .processing
    }

    func receive(interruption: IOSAudioInterruption) {
        if interruption.began, state == .recording { state = .interrupted }
    }

    func resumeAfterInterruption() async {
        guard state == .interrupted else { return }
        do {
            try audioSession.activate()
            state = .recording
        } catch {
            fail("Audio input is not available yet. You can stop and keep the saved recording.")
        }
    }

    func recoverIncompleteRecording() async {
        guard state == .idle else { return }
        let records = try? storage.scan(processingURL: nil)
        if records?.contains(where: { $0.status == .partial }) == true { state = .processing }
    }

    func markProcessingFinished() {
        state = .idle
        currentRecordingURL = nil
    }

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let startedAt = self.startedAt else { return }
                self.elapsed = Date().timeIntervalSince(startedAt)
                self.micLevel *= 0.82
            }
        }
    }

    private func fail(_ message: String) {
        lastError = message
        state = .failed(message)
    }
}

private extension IOSRecordingState {
    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}
