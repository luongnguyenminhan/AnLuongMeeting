import SwiftUI
import AppKit

struct MenuBarView: View {
    @ObservedObject var engine: RecordingEngine
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider().overlay(CelesnityPalette.ivory.opacity(0.14))

            channelRow(
                icon: "speaker.wave.2",
                label: "System Audio",
                muted: Binding(
                    get: { engine.systemMuted },
                    set: { engine.systemMuted = $0 }
                ),
                level: engine.systemLevel
            )

            if engine.systemAudioFailed {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Label("System audio unavailable", systemImage: "exclamationmark.triangle.fill")
                        .font(CelesnityTypography.body(11).weight(.semibold))
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("Fix") { ScreenRecordingPermission.openSettings() }
                        .font(CelesnityTypography.body(11).weight(.semibold))
                        .buttonStyle(.link)
                        .foregroundStyle(CelesnityPalette.ivory)
                }
                .padding(.leading, 24)
            }

            channelRow(
                icon: "mic",
                label: "Microphone",
                muted: Binding(
                    get: { engine.micMuted },
                    set: { engine.micMuted = $0 }
                ),
                level: engine.micLevel
            )

            Text("⌥⌘M mic  ·  ⌥⌘S system  ·  ⌥⌘R record")
                .font(CelesnityTypography.mono(10))
                .foregroundStyle(CelesnityPalette.ivory.opacity(0.48))

            Divider().overlay(CelesnityPalette.ivory.opacity(0.14))
            actionDock
            geminiSurface

            Divider().overlay(CelesnityPalette.ivory.opacity(0.14))
            footer
        }
        .padding(16)
        .frame(width: 340)
        .background(CelesnityPalette.graphite)
        .foregroundStyle(CelesnityPalette.ivory)
    }

    private var header: some View {
        HStack(spacing: 11) {
            Circle()
                .fill(engine.isRecording ? Color.red : CelesnityPalette.ivory.opacity(0.45))
                .frame(width: 11, height: 11)
                .shadow(color: engine.isRecording ? .red.opacity(0.45) : .clear, radius: 6)

            VStack(alignment: .leading, spacing: 2) {
                Text(statusTitle)
                    .font(CelesnityTypography.display(20))
                Text(statusSubtitle)
                    .font(CelesnityTypography.body(11))
                    .foregroundStyle(CelesnityPalette.ivory.opacity(0.56))
            }

            Spacer()

            if engine.isRecording {
                Text(timeString(engine.elapsed))
                    .font(CelesnityTypography.mono(15))
                    .monospacedDigit()
                    .foregroundStyle(CelesnityPalette.ivory.opacity(0.82))
            }
        }
    }

    private var actionDock: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Button {
                    engine.toggle()
                } label: {
                    Label(recordingButtonTitle, systemImage: engine.isRecording ? "stop.fill" : "record.circle")
                        .frame(maxWidth: .infinity)
                }
                .keyboardShortcut(.return, modifiers: [])
                .buttonStyle(.borderedProminent)
                .tint(CelesnityPalette.ivory)
                .foregroundStyle(CelesnityPalette.graphite)
                .disabled(engine.isFinalizing || engine.isTranscribing)

                Button("Open Folder", systemImage: "folder") {
                    NSWorkspace.shared.open(engine.recordingsDirectory)
                }
                .buttonStyle(.bordered)
                .tint(CelesnityPalette.ivory.opacity(0.82))
                .foregroundStyle(CelesnityPalette.ivory)
            }

            Button {
                openWindow(id: "library")
            } label: {
                Label("Open Library", systemImage: "rectangle.stack")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(CelesnityPalette.mistBlue)
            .foregroundStyle(CelesnityPalette.ivory)
            .accessibilityHint("Opens your meeting library")
        }
    }

    private var geminiSurface: some View {
        CelesnitySurface(fill: CelesnityPalette.graphiteRaised, padding: 13) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Label("Gemini transcription", systemImage: "text.bubble")
                        .font(CelesnityTypography.body(13).weight(.semibold))
                    Spacer()
                    Image(systemName: engine.geminiAPIKey.isEmpty ? "key" : "checkmark.shield.fill")
                        .foregroundStyle(engine.geminiAPIKey.isEmpty ? CelesnityPalette.clay : CelesnityPalette.sage)
                        .accessibilityLabel(engine.geminiAPIKey.isEmpty ? "API key missing" : "API key saved")
                }

                SecureField("Gemini API key", text: $engine.geminiAPIKey)
                    .textFieldStyle(.roundedBorder)

                HStack(alignment: .firstTextBaseline) {
                    Text(engine.geminiAPIKey.isEmpty ? "Add a key to create notes" : "Saved securely in Keychain")
                        .font(CelesnityTypography.body(11))
                        .foregroundStyle(CelesnityPalette.ivory.opacity(0.58))
                    Spacer()
                    if !engine.geminiAPIKey.isEmpty {
                        Button("Clear") { engine.geminiAPIKey = "" }
                            .font(CelesnityTypography.body(11).weight(.semibold))
                            .buttonStyle(.link)
                            .foregroundStyle(CelesnityPalette.ivory)
                    }
                }

                transcriptionStatus
            }
        }
    }

    @ViewBuilder
    private var transcriptionStatus: some View {
        switch engine.transcriptionState {
        case .idle:
            EmptyView()
        case .notConfigured:
            Text("Transcription and meeting notes start after recording.")
                .font(CelesnityTypography.body(11))
                .foregroundStyle(CelesnityPalette.ivory.opacity(0.56))
        case .processing(let current, let total):
            Label(
                total > 0 ? "Transcribing segment \(current) of \(total)" : "Preparing transcription",
                systemImage: "arrow.triangle.2.circlepath"
            )
            .font(CelesnityTypography.body(11).weight(.semibold))
            .foregroundStyle(CelesnityPalette.mistBlue)
        case .generatingMeetingNote:
            Label("Generating meeting note", systemImage: "doc.text.magnifyingglass")
                .font(CelesnityTypography.body(11).weight(.semibold))
                .foregroundStyle(CelesnityPalette.mistBlue)
        case .completed(let transcriptURL, let meetingNoteURL):
            VStack(alignment: .leading, spacing: 7) {
                Label("Transcript and note saved", systemImage: "checkmark.circle.fill")
                    .font(CelesnityTypography.body(11).weight(.semibold))
                    .foregroundStyle(CelesnityPalette.sage)
                HStack(spacing: 10) {
                    Button("Transcript") { NSWorkspace.shared.open(transcriptURL) }
                    Button("Meeting note") { NSWorkspace.shared.open(meetingNoteURL) }
                }
                .font(CelesnityTypography.body(11).weight(.semibold))
                .buttonStyle(.link)
                .foregroundStyle(CelesnityPalette.ivory)
            }
        case .failed(let message):
            Text(message)
                .font(CelesnityTypography.body(11))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func channelRow(
        icon: String,
        label: String,
        muted: Binding<Bool>,
        level: Float
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                Label(label, systemImage: icon)
                    .font(CelesnityTypography.body(14).weight(.semibold))
                Spacer()
                Toggle("\(label) active", isOn: Binding(
                    get: { !muted.wrappedValue },
                    set: { muted.wrappedValue = !$0 }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(CelesnityPalette.mistBlue)
            }

            LevelBar(level: level, muted: muted.wrappedValue)
                .frame(height: 5)
                .padding(.leading, 25)
                .accessibilityLabel("\(label) level")
        }
    }

    private var footer: some View {
        HStack {
            if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
                Text("v\(version)")
                    .font(CelesnityTypography.mono(10))
                    .foregroundStyle(CelesnityPalette.ivory.opacity(0.42))
            }
            Spacer()
            Button("Quit Celesnity") { NSApp.terminate(nil) }
                .buttonStyle(.borderless)
                .font(CelesnityTypography.body(11).weight(.semibold))
                .foregroundStyle(CelesnityPalette.ivory.opacity(0.64))
        }
    }

    private var statusTitle: String {
        if engine.isFinalizing { return "Finalizing" }
        if engine.isTranscribing { return "Processing" }
        return engine.isRecording ? "Recording" : "Idle"
    }

    private var statusSubtitle: String {
        if engine.isFinalizing { return "Closing the audio file" }
        if engine.isTranscribing { return "Preparing your meeting artifacts" }
        return engine.isRecording ? "Capturing both sides of the conversation" : "Ready when you are"
    }

    private var recordingButtonTitle: String {
        if engine.isFinalizing { return "Finalizing" }
        if engine.isTranscribing { return "Processing" }
        return engine.isRecording ? "Stop Recording" : "Start Recording"
    }

    private func timeString(_ t: TimeInterval) -> String {
        let total = Int(t)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%02d:%02d", m, s)
    }
}

struct LevelBar: View {
    let level: Float
    let muted: Bool

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(CelesnityPalette.ivory.opacity(0.13))
                Capsule()
                    .fill(muted ? CelesnityPalette.ivory.opacity(0.25) : levelColor)
                    .frame(width: geo.size.width * CGFloat(displayLevel))
                    .animation(.linear(duration: 0.05), value: displayLevel)
            }
        }
    }

    private var displayLevel: Float {
        muted ? 0 : min(max(level, 0), 1)
    }

    private var levelColor: Color {
        switch level {
        case ..<0.6: return CelesnityPalette.sage
        case ..<0.85: return CelesnityPalette.clay
        default: return .red.opacity(0.9)
        }
    }
}
