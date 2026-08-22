import SwiftUI

@main
struct AnLuongMeetingiOSApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var recorder = IOSRecordingCoordinator()
    @StateObject private var pending = IOSPendingWorkCoordinator()
    @StateObject private var notifications = IOSNotificationCoordinator.shared

    var body: some Scene {
        WindowGroup {
            TabView {
                LibraryView(pending: pending)
                    .tabItem { Label("Library", systemImage: "books.vertical") }
                NavigationStack { RecorderView(coordinator: recorder, pending: pending) }
                    .tabItem { Label("Record", systemImage: "waveform") }
                NavigationStack { SettingsView(notifications: notifications) }
                    .tabItem { Label("Settings", systemImage: "gearshape") }
            }
            .task {
                await notifications.refreshStatus()
                await pending.resumePendingWork()
            }
            .onChange(of: recorder.lastFinishedURL) { _, url in
                guard let url else { return }
                pending.enqueue(recordingURL: url)
                Task { await pending.resumePendingWork() }
            }
            .onChange(of: pending.lastCompletedURL) { _, url in
                guard let url, recorder.currentRecordingURL == url else { return }
                recorder.markProcessingFinished()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await pending.resumePendingWork() }
        }
    }
}
