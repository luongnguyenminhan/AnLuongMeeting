import SwiftUI
import AppKit

struct MenuBarView: View {
    @ObservedObject var engine: RecordingEngine
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider().overlay(AnLuongPalette.ivory.opacity(0.14))

            channelRow(
                icon: "speaker.wave.2",
                label: "System Audio",
                muted: Binding(
                    get: { engine.systemMuted },
                    set: { engine.systemMuted = $0 }
                ),
                level: engine.systemLevel
            )

            systemAudioSourcePicker

            if engine.systemAudioFailed {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Label("System audio unavailable", systemImage: "exclamationmark.triangle.fill")
                            .font(AnLuongTypography.body(11).weight(.semibold))
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Fix") { ScreenRecordingPermission.openSettings() }
                            .font(AnLuongTypography.body(11).weight(.semibold))
                            .buttonStyle(.link)
                            .foregroundStyle(AnLuongPalette.ivory)
                    }
                    if let message = engine.systemAudioFailureMessage {
                        Text(message)
                            .font(AnLuongTypography.body(10))
                            .foregroundStyle(AnLuongPalette.ivory.opacity(0.62))
                            .fixedSize(horizontal: false, vertical: true)
                    }
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
                .font(AnLuongTypography.mono(10))
                .foregroundStyle(AnLuongPalette.ivory.opacity(0.48))

            Divider().overlay(AnLuongPalette.ivory.opacity(0.14))
            actionDock
            geminiSurface

            Divider().overlay(AnLuongPalette.ivory.opacity(0.14))
            footer
        }
        .padding(16)
        .frame(width: 340)
        .background(AnLuongPalette.graphite)
        .foregroundStyle(AnLuongPalette.ivory)
        .onAppear { engine.refreshSystemAudioSources() }
    }

    private var systemAudioSourcePicker: some View {
        AnLuongSurface(fill: AnLuongPalette.graphiteRaised, padding: 11) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Label("System audio source", systemImage: "dot.radiowaves.left.and.right")
                        .font(AnLuongTypography.body(12).weight(.semibold))
                    Spacer()
                    if engine.isRefreshingSystemAudioSources {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Button {
                            engine.refreshSystemAudioSources()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(AnLuongPalette.ivory.opacity(0.78))
                        .help("Refresh available applications and windows")
                    }
                }

                Picker(
                    "Capture source",
                    selection: Binding(
                        get: { engine.selectedSystemAudioSource },
                        set: { engine.selectSystemAudioSource($0) }
                    )
                ) {
                    Section("All") {
                        ForEach(engine.systemAudioSources.filter { $0.selection.kind == .all }) { option in
                            sourceOptionLabel(option).tag(option.selection)
                        }
                    }
                    Section("Applications") {
                        ForEach(engine.systemAudioSources.filter { $0.selection.kind == .application }) { option in
                            sourceOptionLabel(option).tag(option.selection)
                        }
                    }
                    Section("Windows") {
                        ForEach(engine.systemAudioSources.filter { $0.selection.kind == .window }) { option in
                            sourceOptionLabel(option).tag(option.selection)
                        }
                    }
                }
                .pickerStyle(.menu)
                .disabled(!engine.canChangeSystemAudioSource)

                if engine.isSelectedSystemAudioSourceUnavailable {
                    Text("The saved source is unavailable. Recording will not silently switch to another source.")
                        .font(AnLuongTypography.body(10))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let error = engine.systemAudioSourceError {
                    Text(error)
                        .font(AnLuongTypography.body(10))
                        .foregroundStyle(AnLuongPalette.ivory.opacity(0.62))
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Changes apply to the next recording.")
                        .font(AnLuongTypography.body(10))
                        .foregroundStyle(AnLuongPalette.ivory.opacity(0.48))
                }
            }
        }
    }

    private func sourceOptionLabel(_ option: SystemAudioSourceOption) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(option.title)
            Text(option.subtitle)
                .font(AnLuongTypography.body(10))
                .foregroundStyle(AnLuongPalette.ivory.opacity(0.52))
        }
        .opacity(option.isAvailable ? 1 : 0.68)
    }

    private var header: some View {
        HStack(spacing: 11) {
            Circle()
                .fill(engine.isRecording ? Color.red : AnLuongPalette.ivory.opacity(0.45))
                .frame(width: 11, height: 11)
                .shadow(color: engine.isRecording ? .red.opacity(0.45) : .clear, radius: 6)

            VStack(alignment: .leading, spacing: 2) {
                Text(statusTitle)
                    .font(AnLuongTypography.display(20))
                Text(statusSubtitle)
                    .font(AnLuongTypography.body(11))
                    .foregroundStyle(AnLuongPalette.ivory.opacity(0.56))
            }

            Spacer()

            if engine.isRecording {
                Text(timeString(engine.elapsed))
                    .font(AnLuongTypography.mono(15))
                    .monospacedDigit()
                    .foregroundStyle(AnLuongPalette.ivory.opacity(0.82))
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
                .tint(AnLuongPalette.ivory)
                .foregroundStyle(AnLuongPalette.graphite)
                .disabled(engine.isFinalizing || engine.isTranscribing)

                Button("Open Folder", systemImage: "folder") {
                    NSWorkspace.shared.open(engine.recordingsDirectory)
                }
                .buttonStyle(.bordered)
                .tint(AnLuongPalette.ivory.opacity(0.82))
                .foregroundStyle(AnLuongPalette.ivory)
            }

            Button {
                openWindow(id: "library")
            } label: {
                Label("Open Library", systemImage: "rectangle.stack")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(AnLuongPalette.mistBlue)
            .foregroundStyle(AnLuongPalette.ivory)
            .accessibilityHint("Opens your meeting library")
        }
    }

    private var geminiSurface: some View {
        AnLuongSurface(fill: AnLuongPalette.graphiteRaised, padding: 13) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Label("Gemini transcription", systemImage: "text.bubble")
                        .font(AnLuongTypography.body(13).weight(.semibold))
                    Spacer()
                    Image(systemName: engine.geminiAPIKey.isEmpty ? "key" : "checkmark.shield.fill")
                        .foregroundStyle(engine.geminiAPIKey.isEmpty ? AnLuongPalette.clay : AnLuongPalette.sage)
                        .accessibilityLabel(engine.geminiAPIKey.isEmpty ? "API key missing" : "API key saved")
                }

                SecureField("Gemini API key", text: $engine.geminiAPIKey)
                    .textFieldStyle(.roundedBorder)

                HStack(alignment: .firstTextBaseline) {
                    Text(engine.geminiAPIKey.isEmpty ? "Add a key to create notes" : "Saved securely in Keychain")
                        .font(AnLuongTypography.body(11))
                        .foregroundStyle(AnLuongPalette.ivory.opacity(0.58))
                    Spacer()
                    if !engine.geminiAPIKey.isEmpty {
                        Button("Clear") { engine.geminiAPIKey = "" }
                            .font(AnLuongTypography.body(11).weight(.semibold))
                            .buttonStyle(.link)
                            .foregroundStyle(AnLuongPalette.ivory)
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
                .font(AnLuongTypography.body(11))
                .foregroundStyle(AnLuongPalette.ivory.opacity(0.56))
        case .processing(let current, let total):
            Label(
                total > 0 ? "Transcribing segment \(current) of \(total)" : "Preparing transcription",
                systemImage: "arrow.triangle.2.circlepath"
            )
            .font(AnLuongTypography.body(11).weight(.semibold))
            .foregroundStyle(AnLuongPalette.mistBlue)
        case .generatingMeetingNote:
            Label("Generating meeting note", systemImage: "doc.text.magnifyingglass")
                .font(AnLuongTypography.body(11).weight(.semibold))
                .foregroundStyle(AnLuongPalette.mistBlue)
        case .completed(let transcriptURL, let meetingNoteURL):
            VStack(alignment: .leading, spacing: 7) {
                Label("Transcript and note saved", systemImage: "checkmark.circle.fill")
                    .font(AnLuongTypography.body(11).weight(.semibold))
                    .foregroundStyle(AnLuongPalette.sage)
                HStack(spacing: 10) {
                    Button("Transcript") { NSWorkspace.shared.open(transcriptURL) }
                    Button("Meeting note") { NSWorkspace.shared.open(meetingNoteURL) }
                }
                .font(AnLuongTypography.body(11).weight(.semibold))
                .buttonStyle(.link)
                .foregroundStyle(AnLuongPalette.ivory)
            }
        case .failed(let message):
            Text(message)
                .font(AnLuongTypography.body(11))
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
                    .font(AnLuongTypography.body(14).weight(.semibold))
                Spacer()
                Toggle("\(label) active", isOn: Binding(
                    get: { !muted.wrappedValue },
                    set: { muted.wrappedValue = !$0 }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(AnLuongPalette.mistBlue)
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
                    .font(AnLuongTypography.mono(10))
                    .foregroundStyle(AnLuongPalette.ivory.opacity(0.42))
            }
            Spacer()
            Button("Quit AnLuong") { NSApp.terminate(nil) }
                .buttonStyle(.borderless)
                .font(AnLuongTypography.body(11).weight(.semibold))
                .foregroundStyle(AnLuongPalette.ivory.opacity(0.64))
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
                    .fill(AnLuongPalette.ivory.opacity(0.13))
                Capsule()
                    .fill(muted ? AnLuongPalette.ivory.opacity(0.25) : levelColor)
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
        case ..<0.6: return AnLuongPalette.sage
        case ..<0.85: return AnLuongPalette.clay
        default: return .red.opacity(0.9)
        }
    }
}
