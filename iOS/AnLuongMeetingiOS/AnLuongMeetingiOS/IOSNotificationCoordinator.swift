import Foundation
import Combine
import UserNotifications

@MainActor
protocol IOSNotificationSink: AnyObject {
    func notifyTranscriptReady()
    func notifyMeetingNoteReady()
    func notifyProcessingFailed()
}

@MainActor
final class IOSNotificationCoordinator: NSObject, ObservableObject, UNUserNotificationCenterDelegate, IOSNotificationSink {
    static let shared = IOSNotificationCoordinator()

    @Published private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined

    private let center = UNUserNotificationCenter.current()

    private override init() {
        super.init()
        center.delegate = self
    }

    var statusTitle: String {
        switch authorizationStatus {
        case .authorized, .provisional, .ephemeral: return "Notifications allowed"
        case .denied: return "Notifications turned off"
        case .notDetermined: return "Notifications not configured"
        @unknown default: return "Notification status unavailable"
        }
    }

    var canNotify: Bool {
        switch authorizationStatus {
        case .authorized, .provisional, .ephemeral: return true
        default: return false
        }
    }

    func refreshStatus() async {
        let settings = await center.notificationSettings()
        authorizationStatus = settings.authorizationStatus
    }

    func requestPermission() async {
        do {
            _ = try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            // The current authorization status remains the source of truth for the UI.
        }
        await refreshStatus()
    }

    func notifyTranscriptReady() {
        schedule(
            identifierPrefix: "transcription-complete",
            title: "Transcription complete",
            body: "Your meeting transcript is ready to review."
        )
    }

    func notifyMeetingNoteReady() {
        schedule(
            identifierPrefix: "meeting-note-ready",
            title: "Meeting note ready",
            body: "Your meeting note has been generated and is ready to review."
        )
    }

    func notifyProcessingFailed() {
        schedule(
            identifierPrefix: "meeting-processing-failed",
            title: "Meeting processing failed",
            body: "Open AnLuongMeeting to review the error and retry."
        )
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .badge]
    }

    private func schedule(identifierPrefix: String, title: String, body: String) {
        guard canNotify else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "\(identifierPrefix)-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        center.add(request)
    }
}
