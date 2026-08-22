// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AnLuongMeetingCore",
    platforms: [
        .iOS("17.0"),
        .macOS("14.2")
    ],
    products: [
        .library(name: "AnLuongMeetingCore", targets: ["AnLuongMeetingCore"])
    ],
    targets: [
        .target(
            name: "AnLuongMeetingCore",
            linkerSettings: [.linkedFramework("AVFoundation")]
        ),
        .testTarget(
            name: "AnLuongMeetingCoreTests",
            dependencies: ["AnLuongMeetingCore"]
        )
    ]
)
