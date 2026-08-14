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
        // CLI の中身はここに置く。**`main.swift` のトップレベルコードは検査できない**ので、
        // 出力文言・引数解析・終了の待ち合わせをライブラリ側へ出して検査対象にする。
        .target(name: "GhostVoiceCLI", dependencies: ["GhostVoiceCore"]),
        .executableTarget(name: "ghost-voice", dependencies: ["GhostVoiceCLI"]),
        .testTarget(
            name: "GhostVoiceCoreTests", dependencies: ["GhostVoiceCore", "GhostVoiceCLI"]),
    ],
    swiftLanguageModes: [.v6]
)
