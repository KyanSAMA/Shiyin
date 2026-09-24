// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "LocalMusic",
    platforms: [.macOS(.v27)],
    targets: [
        .target(name: "LocalMusicCore"),
        .executableTarget(
            name: "LocalMusic",
            dependencies: ["LocalMusicCore"],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .executableTarget(name: "lmtool", dependencies: ["LocalMusicCore"]),
        .testTarget(
            name: "LocalMusicCoreTests",
            dependencies: ["LocalMusicCore"],
            // Command Line Tools ship TestingMacros here but SwiftPM does not pass it to test targets.
            swiftSettings: [.unsafeFlags(["-plugin-path", "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing"])]
        ),
    ]
)
