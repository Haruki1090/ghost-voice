import Foundation
import os

/// アプリの診断出力。
///
/// **`.app` を Finder から起動すると標準エラーはどこにも出ない**（親は launchd）。
/// そこで unified log にも同じ内容を流す。読むときは:
///
/// ```
/// log stream --predicate 'subsystem == "com.haruki1090.GhostVoice"' --level info
/// ```
///
/// **フェーズ 2 の HUD ができるまで、利用者が起動時の案内を読む唯一の経路である。**
/// 音声・認識テキストは**絶対に流さない**（FR-12 / NFR-V2）。ここへ渡してよいのは
/// 権限・起動・終了の事実だけである。
public enum AppDiagnostics {

    /// 発話内容が混ざる余地を無くすため、`Logger` へは**固定文字列の書式**でしか渡さない。
    /// **バンドル ID を literal で二重に持たない**（正は `Resources/Info.plist`）。
    /// `.app` の外から実行したときだけ、それと判る別の名前になる。
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "GhostVoice.unbundled", category: "app")

    public static func note(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        logger.log("\(message, privacy: .public)")
    }
}
