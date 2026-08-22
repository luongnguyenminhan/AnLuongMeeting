import AVFoundation
import Combine

struct IOSAudioInterruption: Equatable {
    let began: Bool
    let reason: String
}

@MainActor
final class IOSAudioSessionController: ObservableObject {
    @Published private(set) var interruptionMessage: String?
    @Published private(set) var routeDescription = "Built-in microphone"

    var onInterruption: ((IOSAudioInterruption) -> Void)?

    private let session = AVAudioSession.sharedInstance()
    private var observers: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) { [weak self] notification in
            guard let info = notification.userInfo,
                  let rawType = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }
            Task { @MainActor in
                let began = type == .began
                self?.interruptionMessage = began ? "Audio interrupted" : nil
                self?.onInterruption?(IOSAudioInterruption(
                    began: began,
                    reason: began ? "Another app is using audio input." : "Audio input is available again."
                ))
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: .main) { [weak self] notification in
            let route = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            Task { @MainActor in
                self?.routeDescription = route == AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue
                    ? "External microphone"
                    : "Microphone input"
            }
        })
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    func activate() throws {
        try session.setCategory(.record, mode: .measurement, options: [.allowBluetoothHFP])
        try session.setActive(true, options: .notifyOthersOnDeactivation)
    }

    func deactivate() {
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
    }
}
