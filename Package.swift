// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AnLuongMeeting",
    platforms: [.macOS("14.2")],
    targets: [
        .executableTarget(
            name: "AnLuongMeeting",
            path: "Sources/AnLuongMeeting",
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
            name: "AnLuongMeetingTests",
            dependencies: ["AnLuongMeeting"],
            path: "Tests/AnLuongMeetingTests"
        )
    ]
)
