// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "CelesnityMeeting",
    platforms: [.macOS("14.2")],
    targets: [
        .executableTarget(
            name: "CelesnityMeeting",
            path: "Sources/CelesnityMeeting",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("Security"),
            ]
        ),
        .testTarget(
            name: "CelesnityMeetingTests",
            dependencies: ["CelesnityMeeting"],
            path: "Tests/CelesnityMeetingTests"
        )
    ]
)
