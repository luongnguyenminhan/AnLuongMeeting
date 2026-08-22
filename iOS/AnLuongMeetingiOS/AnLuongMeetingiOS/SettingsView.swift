import SwiftUI
import UserNotifications
import AnLuongMeetingCore

struct SettingsView: View {
    @ObservedObject var notifications: IOSNotificationCoordinator
    @State private var apiKey: String
    @State private var saveMessage: String?
    @State private var testMessage: String?
    @State private var isTesting = false
    private let keyStore = IOSAPIKeyStore()

    init(notifications: IOSNotificationCoordinator) {
        self.notifications = notifications
        _apiKey = State(initialValue: IOSAPIKeyStore().load() ?? "")
    }

    var body: some View {
        Form {
            Section("Gemini") {
                SecureField("API key", text: $apiKey)
                Button("Save API key") {
                    do {
                        try keyStore.save(apiKey)
                        saveMessage = "Saved securely in Keychain."
                    } catch {
                        saveMessage = error.localizedDescription
                    }
                }
                Button {
                    testAPIKey()
                } label: {
                    if isTesting {
                        ProgressView()
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Label("Test API key", systemImage: "checkmark.shield")
                    }
                }
                .disabled(isTesting || apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if let saveMessage { Text(saveMessage).font(.caption).foregroundStyle(.secondary) }
                if let testMessage {
                    Text(testMessage)
                        .font(.caption)
                        .foregroundStyle(testMessage.hasPrefix("API key works") ? .green : .red)
                }
                Text("The test makes a small authenticated Gemini model request and does not upload a recording.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("Notifications") {
                Label(notifications.statusTitle, systemImage: notificationIcon)
                Button(notificationButtonTitle) {
                    Task { await notifications.requestPermission() }
                }
                .disabled(notifications.canNotify)
                Text("Allow notifications to be told when a meeting finishes or processing fails. Notification text never includes transcript content.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("Recording") {
                Label("Microphone only", systemImage: "mic")
                Text("AnLuongMeeting continues recording while the app is in the background or the screen is locked. Force-quitting the app stops recording.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Settings")
        .task { await notifications.refreshStatus() }
    }

    private var notificationButtonTitle: String {
        switch notifications.authorizationStatus {
        case .denied: return "Enable notifications in iPhone Settings"
        case .authorized, .provisional, .ephemeral: return "Notifications enabled"
        default: return "Allow notifications"
        }
    }

    private var notificationIcon: String {
        notifications.canNotify ? "bell.badge.fill" : "bell.slash"
    }

    private func testAPIKey() {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        isTesting = true
        testMessage = nil
        Task {
            defer { isTesting = false }
            do {
                try await GeminiTranscriptionService().testAPIKey(apiKey: key)
                testMessage = "API key works. Gemini accepted the key."
            } catch {
                testMessage = "API key test failed: \(error.localizedDescription)"
            }
        }
    }
}
