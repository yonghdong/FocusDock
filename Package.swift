// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "FocusDock",
    platforms: [.macOS(.v13)],
    targets: [
        // All logic + UI. Tests import this.
        .target(
            name: "FocusDockKit",
            path: "Sources/FocusDockKit",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
            ]
        ),
        // Thin entry point (main.swift only).
        .executableTarget(
            name: "FocusDock",
            dependencies: ["FocusDockKit"],
            path: "Sources/FocusDock"
        ),
        .testTarget(
            name: "FocusDockKitTests",
            dependencies: ["FocusDockKit"],
            path: "Tests/FocusDockKitTests"
        ),
    ]
)
