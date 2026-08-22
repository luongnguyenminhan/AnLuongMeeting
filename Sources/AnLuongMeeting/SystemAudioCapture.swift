import Foundation
import AVFoundation
import ScreenCaptureKit
import CoreMedia

enum SystemAudioSourceKind: String, Codable, CaseIterable, Identifiable {
    case all
    case application
    case window

    var id: String { rawValue }
}

struct SystemAudioSourceSelection: Codable, Equatable, Hashable, Identifiable {
    let kind: SystemAudioSourceKind
    let bundleIdentifier: String?
    let applicationName: String?
    let windowID: UInt32?
    let windowTitle: String?

    static let all = SystemAudioSourceSelection(
        kind: .all,
        bundleIdentifier: nil,
        applicationName: nil,
        windowID: nil,
        windowTitle: nil
    )

    static func application(bundleIdentifier: String, name: String) -> Self {
        Self(
            kind: .application,
            bundleIdentifier: bundleIdentifier,
            applicationName: name,
            windowID: nil,
            windowTitle: nil
        )
    }

    static func window(
        windowID: UInt32,
        bundleIdentifier: String,
        applicationName: String,
        title: String
    ) -> Self {
        Self(
            kind: .window,
            bundleIdentifier: bundleIdentifier,
            applicationName: applicationName,
            windowID: windowID,
            windowTitle: title
        )
    }

    var id: String {
        switch kind {
        case .all:
            return "all"
        case .application:
            return "application:\(bundleIdentifier ?? applicationName ?? "unknown")"
        case .window:
            if let windowID {
                return "window:\(windowID)"
            }
            return "window:\(bundleIdentifier ?? "unknown"):\(windowTitle ?? "unknown")"
        }
    }

    var displayName: String {
        switch kind {
        case .all:
            return "All system audio"
        case .application:
            return applicationName ?? bundleIdentifier ?? "Application"
        case .window:
            return windowTitle ?? applicationName ?? "Window"
        }
    }

    /// Matches a newly discovered source while allowing its display name or
    /// window ID to change between launches.
    func matchesDiscovered(_ other: Self) -> Bool {
        guard kind == other.kind else { return false }
        switch kind {
        case .all:
            return true
        case .application:
            return bundleIdentifier == other.bundleIdentifier
        case .window:
            if let windowID, let otherWindowID = other.windowID, windowID == otherWindowID {
                return true
            }
            return bundleIdentifier == other.bundleIdentifier && windowTitle == other.windowTitle
        }
    }
}

struct SystemAudioSourceOption: Identifiable, Hashable {
    let selection: SystemAudioSourceSelection
    let title: String
    let subtitle: String
    let isAvailable: Bool

    var id: String { selection.id }

    static let all = SystemAudioSourceOption(
        selection: .all,
        title: "All system audio",
        subtitle: "Capture eligible audio from the selected display",
        isAvailable: true
    )

    static func application(bundleIdentifier: String, name: String) -> Self {
        Self(
            selection: .application(bundleIdentifier: bundleIdentifier, name: name),
            title: name,
            subtitle: "Application audio",
            isAvailable: true
        )
    }

    static func window(
        windowID: UInt32,
        bundleIdentifier: String,
        applicationName: String,
        title: String
    ) -> Self {
        Self(
            selection: .window(
                windowID: windowID,
                bundleIdentifier: bundleIdentifier,
                applicationName: applicationName,
                title: title
            ),
            title: title,
            subtitle: "Window in \(applicationName)",
            isAvailable: true
        )
    }

    static func unavailable(for selection: SystemAudioSourceSelection) -> Self {
        Self(
            selection: selection,
            title: "Unavailable: \(selection.displayName)",
            subtitle: "Refresh sources or choose another source",
            isAvailable: false
        )
    }
}

enum AudioCaptureError: LocalizedError {
    case noDisplays
    case noPermission
    case sourceUnavailable(String)
    case streamStartFailed(Error)

    var errorDescription: String? {
        switch self {
        case .noDisplays:
            return "No display is available for system-audio capture."
        case .noPermission:
            return "Screen Recording permission is required for system-audio capture."
        case .sourceUnavailable(let source):
            return "The selected audio source is no longer available: \(source)."
        case .streamStartFailed(let error):
            return "ScreenCaptureKit could not start: \(error.localizedDescription)"
        }
    }
}

extension SystemAudioSourceSelection {
    private static let preferencesKey = "SystemAudioSourceSelection"

    static func loadSaved() -> Self {
        guard let data = UserDefaults.standard.data(forKey: preferencesKey),
              let selection = try? JSONDecoder().decode(Self.self, from: data) else {
            return .all
        }
        return selection
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.preferencesKey)
    }
}

/// System-audio capture via ScreenCaptureKit. Works on built-in speakers,
/// Bluetooth (AirPods), and external DACs — unlike Core Audio Process Taps
/// which fails when output is routed through HFP/SCO Bluetooth.
final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate {

    private var stream: SCStream?
    private let audioQueue = DispatchQueue(label: "com.anluong.meeting.sck-audio", qos: .userInitiated)
    private var handleCount = 0

    var onBuffer: ((AVAudioPCMBuffer, AVAudioTime) -> Void)?

    static func discoverSources() async throws -> [SystemAudioSourceOption] {
        Log.write("sck: requesting shareable content for source list")
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: false
            )
        } catch {
            Log.write("sck: source discovery FAILED — likely missing Screen Recording permission. \(error)")
            throw AudioCaptureError.noPermission
        }

        let currentBundleID = Bundle.main.bundleIdentifier
        var options = [SystemAudioSourceOption.all]
        var applicationIDs = Set<String>()

        for application in content.applications.sorted(by: {
            $0.applicationName.localizedCaseInsensitiveCompare($1.applicationName) == .orderedAscending
        }) {
            let bundleID = application.bundleIdentifier
            guard !bundleID.isEmpty, bundleID != currentBundleID else { continue }
            guard applicationIDs.insert(bundleID).inserted else { continue }
            options.append(.application(
                bundleIdentifier: bundleID,
                name: application.applicationName
            ))
        }

        let windows = content.windows
            .compactMap { window -> (SCWindow, String, String, String)? in
                guard let title = window.title?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !title.isEmpty,
                      let application = window.owningApplication,
                      let bundleID = Optional(application.bundleIdentifier),
                      !bundleID.isEmpty,
                      bundleID != currentBundleID else {
                    return nil
                }
                return (window, bundleID, application.applicationName, title)
            }
            .sorted {
                let left = "\($0.2) \($0.3)"
                let right = "\($1.2) \($1.3)"
                return left.localizedCaseInsensitiveCompare(right) == .orderedAscending
            }

        var windowIDs = Set<UInt32>()
        for (window, bundleID, applicationName, title) in windows {
            let windowID = UInt32(window.windowID)
            guard windowIDs.insert(windowID).inserted else { continue }
            options.append(.window(
                windowID: windowID,
                bundleIdentifier: bundleID,
                applicationName: applicationName,
                title: title
            ))
        }

        return options
    }

    func start(source: SystemAudioSourceSelection) async throws {
        Log.write("sck: requesting shareable content for \(source.displayName)")
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: false
            )
        } catch {
            Log.write("sck: SCShareableContent FAILED — likely missing Screen Recording permission. \(error)")
            throw AudioCaptureError.noPermission
        }

        guard let display = content.displays.first else {
            Log.write("sck: no displays found")
            throw AudioCaptureError.noDisplays
        }

        let filter: SCContentFilter
        switch source.kind {
        case .all:
            Log.write("sck: using display-wide audio source \(display.displayID) \(display.width)x\(display.height)")
            filter = SCContentFilter(display: display, excludingWindows: [])

        case .application:
            guard let bundleID = source.bundleIdentifier,
                  let application = content.applications.first(where: { $0.bundleIdentifier == bundleID }) else {
                throw AudioCaptureError.sourceUnavailable(source.displayName)
            }
            Log.write("sck: using application audio source \(application.applicationName) (\(bundleID))")
            filter = SCContentFilter(
                display: display,
                including: [application],
                exceptingWindows: []
            )

        case .window:
            let matchingWindow = content.windows.first { window in
                if let windowID = source.windowID, UInt32(window.windowID) == windowID {
                    return true
                }
                return window.owningApplication?.bundleIdentifier == source.bundleIdentifier
                    && window.title == source.windowTitle
            }
            guard let matchingWindow else {
                throw AudioCaptureError.sourceUnavailable(source.displayName)
            }
            Log.write("sck: using window audio source \(source.displayName) (\(matchingWindow.windowID))")
            filter = SCContentFilter(desktopIndependentWindow: matchingWindow)
        }

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        config.excludesCurrentProcessAudio = true
        // We don't care about video frames; keep them minimal so they don't cost us much.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1) // ~1 fps, discarded
        config.queueDepth = 6
        config.showsCursor = false

        handleCount = 0
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        Log.write("sck: stream created, starting capture")

        do {
            try await stream.startCapture()
        } catch {
            Log.write("sck: startCapture FAILED — \(error)")
            throw AudioCaptureError.streamStartFailed(error)
        }

        self.stream = stream
        Log.write("sck: STARTED ✓ (source=\(source.displayName), sr=48000, ch=2)")
    }

    func stop() async {
        do {
            try await stream?.stopCapture()
            Log.write("sck: stopped, total buffers=\(handleCount)")
        } catch {
            Log.write("sck: stop error \(error)")
        }
        stream = nil
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .audio else { return }
        guard sampleBuffer.isValid else { return }

        handleCount += 1
        if handleCount == 1 || handleCount % 200 == 0 {
            Log.write("sck: audio buffer #\(handleCount) samples=\(sampleBuffer.numSamples)")
        }

        guard let pcm = pcmBuffer(from: sampleBuffer) else { return }
        let time = AVAudioTime(sampleTime: AVAudioFramePosition(handleCount), atRate: 48_000)
        onBuffer?(pcm, time)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.write("sck: stream stopped with error \(error)")
    }

    // MARK: - CMSampleBuffer → AVAudioPCMBuffer

    private func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDesc = sampleBuffer.formatDescription,
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else {
            return nil
        }
        var asbd = asbdPtr.pointee
        guard let format = AVAudioFormat(streamDescription: &asbd) else { return nil }

        let frameCount = AVAudioFrameCount(sampleBuffer.numSamples)
        guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return nil }
        pcm.frameLength = frameCount

        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: pcm.mutableAudioBufferList
        )
        guard status == noErr else {
            Log.write("sck: copy PCM data failed status=\(status)")
            return nil
        }
        return pcm
    }
}
