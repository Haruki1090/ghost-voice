import AppKit

/// 常駐アプリの入口。**`main.swift` は 1 行だけ**にして、判断はすべてこちら側に置く
/// （トップレベルコードは検査できないため。CLI と同じ形）。
///
/// ## `NSApplication.run()` を使う理由
///
/// フェーズ 1 の CLI は `while !isShuttingDown { CFRunLoopRun() }` で自前にメインの
/// ランループを回していた。アプリでは `NSApp.run()` に置き換える——SwiftUI／AppKit の
/// ビュー更新・アニメーション・イベント処理は `NSApplication` のイベントループに依存する。
///
/// **`CGEventTap` は `CFRunLoopGetMain()` の `.commonModes` に載る**
/// （`CGEventTapHotkeyMonitor.swift`）。`NSApp.run()` はメインの CFRunLoop を回すので
/// 両立するはずだが、**これは実測されていない**（タップ生成は入力監視の権限を要するため、
/// 権限の無い環境では確かめられない）。**詳細設計書 §13 の V-19 として登録してある。**
/// 実施手順は README の「フェーズ 2: `.app` の権限移行」にある。
@MainActor
public enum GhostVoiceAppMain {

    /// - Parameter surfaces: 画面の工場。**別トラックがここへ HUD・設定画面を足す。**
    ///   工場は `NSApplication.run()` のイベントループが回り始めた後にしか呼ばれない
    ///   （`LaunchSequence` / `RunLoopEntry`）。
    public static func main(surfaces: [AppSurfaceFactory] = []) -> Never {
        let options = AppLaunchOptions.parse(Array(CommandLine.arguments.dropFirst()))
        let application = NSApplication.shared
        let delegate = GhostVoiceAppDelegate(options: options, surfaces: surfaces)
        application.delegate = delegate
        // **ここで window を作らない。** `delegate` も window を持たない。
        application.run()
        // `run()` は `terminate` の後にしか戻らない。
        exit(0)
    }
}
