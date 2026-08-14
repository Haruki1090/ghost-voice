// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "GhostVoiceCore",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "GhostVoiceCore", targets: ["GhostVoiceCore"]),
        .executable(name: "ghost-voice", targets: ["ghost-voice"]),
        // 常駐アプリの実行ファイル。**単体では `.app` にならない。**
        // `Scripts/make-app.sh` がこの実行ファイルを `Ghost Voice.app` へ組み立てて署名する
        // （`.xcodeproj` は作らない。フェーズ 2 の裁定）。
        .executable(name: "GhostVoice", targets: ["GhostVoice"]),
    ],
    targets: [
        .target(name: "GhostVoiceCore"),
        // CLI の中身はここに置く。**`main.swift` のトップレベルコードは検査できない**ので、
        // 出力文言・引数解析・終了の待ち合わせをライブラリ側へ出して検査対象にする。
        .target(name: "GhostVoiceCLI", dependencies: ["GhostVoiceCore"]),
        .executableTarget(name: "ghost-voice", dependencies: ["GhostVoiceCLI"]),
        // 常駐アプリの中身。CLI とまったく同じ形（薄い `@main` + 厚い検査可能ライブラリ）。
        .target(
            name: "GhostVoiceApp", dependencies: ["GhostVoiceCore"],
            path: "Sources/GhostVoiceApp/Shell"),
        .executableTarget(
            name: "GhostVoice", dependencies: ["GhostVoiceApp"],
            path: "Sources/GhostVoiceApp/Main"),
        .testTarget(
            name: "GhostVoiceCoreTests", dependencies: ["GhostVoiceCore", "GhostVoiceCLI"]),
        .testTarget(name: "GhostVoiceAppTests", dependencies: ["GhostVoiceApp"]),
    ],
    swiftLanguageModes: [.v6]
)
