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
/// （`CGEventTapHotkeyMonitor.swift`）。**`NSApp.run()` の下でも `.commonModes` のソースが
/// 処理されることは実測した**（2026-08-14。タップと同じ形の `CFMachPort` 由来ソースを含む
/// 4 系統、登録の前後、メニュー追跡中・モーダル中・バンドル内。詳細設計書 §7.2）。
///
/// **ただしタップ固有の振る舞いは依然として未実測である**（`CGEvent.tapCreate` は
/// 入力監視の権限ダイアログを誘発するので呼んでいない）。キーイベントが実際に配送されるか、
/// `return nil` による抑止が効くかは**詳細設計書 §13 の V-19 として残っている。**
/// 実施手順は README の「フェーズ 2: `Ghost Voice.app` への移行」にある。
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
