import SwiftUI
import AnLuongMeetingCore

enum IOSProcessingStatusPresentation {
    static func shouldShowProgressMessage(_ progressMessage: String, errorMessage: String?) -> Bool {
        !progressMessage.isEmpty && errorMessage == nil
    }
}

struct RecorderView: View {
    @ObservedObject var coordinator: IOSRecordingCoordinator
    @ObservedObject var pending: IOSPendingWorkCoordinator

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                Spacer(minLength: 18)
                Image(systemName: coordinator.state == .recording ? "waveform.circle.fill" : "waveform.circle")
                    .font(.system(size: 74))
                    .foregroundStyle(coordinator.state == .recording ? Color.red : Color.accentColor)
                Text(title)
                    .font(.title.bold())
                Text(timeString(coordinator.elapsed))
                    .font(.system(size: 44, design: .monospaced).weight(.medium))
                    .monospacedDigit()
                MicLevelView(level: coordinator.micLevel)
                    .frame(height: 10)
                    .padding(.horizontal, 34)
                Text("Microphone only · recording continues when the screen is locked")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
                Button(action: action) {
                    Label(buttonTitle, systemImage: coordinator.state == .recording ? "stop.fill" : "mic.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                }
                .buttonStyle(.borderedProminent)
                .tint(coordinator.state == .recording ? .red : .accentColor)
                .padding(.horizontal, 28)
                .disabled(coordinator.state == .requestingPermission || coordinator.state == .finalizing)
                if case .failed(let message) = coordinator.state {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 28)
                }
                if pending.shouldShowStatusCard {
                    IOSProcessingStatusCard(pending: pending)
                        .padding(.horizontal, 8)
                }
                Spacer(minLength: 18)
            }
            .padding()
        }
        .navigationTitle("Record")
    }

    private var title: String {
        switch coordinator.state {
        case .recording: return "Recording"
        case .interrupted: return "Audio interrupted"
        case .finalizing: return "Saving recording"
        case .processing: return "Processing meeting"
        case .requestingPermission: return "Checking microphone"
        case .failed: return "Recording unavailable"
        case .idle: return "Ready to record"
        }
    }

    private var buttonTitle: String { coordinator.state == .recording || coordinator.state == .interrupted ? "Stop recording" : "Start recording" }

    private func action() {
        if coordinator.state == .recording || coordinator.state == .interrupted { coordinator.stop() }
        else { Task { await coordinator.start() } }
    }

    private func timeString(_ time: TimeInterval) -> String {
        let total = Int(time)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

struct IOSProcessingStatusCard: View {
    @ObservedObject var pending: IOSPendingWorkCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Label(title, systemImage: icon)
                    .font(.headline)
                Spacer()
                if pending.queueTotal > 1 {
                    Text("\(pending.queuePosition) of \(pending.queueTotal)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            if case .processing(_, let current, let total) = pending.processingState, total > 0 {
                ProgressView(value: Double(current), total: Double(total))
                Text("Segment \(current) of \(total)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if isBusy {
                ProgressView()
            }
            if IOSProcessingStatusPresentation.shouldShowProgressMessage(
                pending.progressMessage,
                errorMessage: pending.errorMessage
            ) {
                Text(pending.progressMessage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if isBusy {
                Text("Keep AnLuongMeeting open while Gemini processes the recording. You can continue using the app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Cancel processing", systemImage: "xmark.circle", role: .cancel) {
                    pending.cancelProcessing()
                }
                .font(.subheadline)
            } else if case .failed = pending.processingState {
                Button("Retry", systemImage: "arrow.clockwise") {
                    pending.retryLastOperation()
                }
                .buttonStyle(.borderedProminent)
            } else if let error = pending.errorMessage {
                Text(error)
                    .font(.subheadline)
                    .foregroundStyle(.red)
                Button("Dismiss") { pending.clearError() }
                    .font(.subheadline)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background, in: RoundedRectangle(cornerRadius: 14))
    }

    private var isBusy: Bool { pending.processingState.isBusy }

    private var title: String {
        switch pending.processingState {
        case .processing(let mode, _, _): return modeTitle(mode)
        case .generatingMeetingNote(let mode): return modeTitle(mode)
        case .failed: return "Processing failed"
        case .completed: return "Processing complete"
        case .idle: return pending.pendingURLs.isEmpty ? "Processing status" : "Waiting to process"
        }
    }

    private var icon: String {
        switch pending.processingState {
        case .failed: return "exclamationmark.triangle"
        case .completed: return "checkmark.circle"
        case .idle: return "clock"
        case .processing, .generatingMeetingNote: return "arrow.triangle.2.circlepath"
        }
    }

    private var background: Color {
        switch pending.processingState {
        case .failed: return .red.opacity(0.12)
        case .completed: return .green.opacity(0.12)
        default: return Color.accentColor.opacity(0.10)
        }
    }

    private func modeTitle(_ mode: GeminiRegenerationMode) -> String {
        switch mode {
        case .transcriptOnly: return "Processing transcript"
        case .noteOnly: return "Generating meeting note"
        case .both: return "Processing meeting"
        }
    }
}

private struct MicLevelView: View {
    let level: Float
    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.secondary.opacity(0.16))
                Capsule().fill(Color.accentColor).frame(width: max(8, proxy.size.width * CGFloat(level)))
            }
        }
    }
}
