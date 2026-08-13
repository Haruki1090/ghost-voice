// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "GhostVoiceCore",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "GhostVoiceCore", targets: ["GhostVoiceCore"]),
        .executable(name: "ghost-voice", targets: ["ghost-voice"]),
    ],
    targets: [
        .target(name: "GhostVoiceCore"),
        .executableTarget(name: "ghost-voice", dependencies: ["GhostVoiceCore"]),
        .testTarget(name: "GhostVoiceCoreTests", dependencies: ["GhostVoiceCore"]),
    ],
    swiftLanguageModes: [.v6]
)
