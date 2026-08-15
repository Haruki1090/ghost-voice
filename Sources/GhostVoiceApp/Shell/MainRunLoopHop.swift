import CoreFoundation
import Foundation

/// メインスレッドへ仕事を渡す作法。**`DispatchQueue.main.async` を使ってはならない。**
///
/// ## なぜ専用の型が要るのか（実機で失った 17 分）
///
/// **メインの *ディスパッチキュー* のブロックを実行している間、入れ子のランループを
/// いくら回してもメインキューは 1 件も進まない。** libdispatch の
/// `_dispatch_main_queue_callback_4CF` は「いま排出中なら何もせず戻る」ので、
/// 入れ子のランループから呼ばれても再入しない。
///
/// **Swift の `MainActor` はメインキューへ積む。** したがって、メインキューのブロックの
/// 中で入れ子のランループへ入ると、**そこから積んだ `Task { @MainActor in … }` は
/// 二度と走らない。**
///
/// これが実機の欠陥そのものだった。`SIGTERM` の受け口が `DispatchSource`(`queue: .main`)
/// だったため:
///
/// 1. ハンドラが**メインキューのブロックとして**走る
/// 2. その中で `NSApp.terminate(nil)` を呼ぶ
/// 3. `applicationShouldTerminate` が `.terminateLater` を返す
/// 4. AppKit は**返事が来るまで入れ子のランループを回す**（ここから戻らない）
/// 5. 返事をするのは `Task { await runtime.shutdown() … }`＝**メインキューへ積まれる**
/// 6. 1 のブロックがまだ排出中なので 5 は永久に走らない → **返事が来ない → 終わらない**
///
/// 実測（2026-08-15 / M3 / macOS 26.5.2。使い捨てプログラム。`scratchpad/probe`）:
///
/// | メインへの渡し方 | 入れ子のランループの間に走ったか |
/// |---|---|
/// | `DispatchQueue.main.async` | **走らない** |
/// | `CFRunLoopPerformBlock`（この型） | 走る |
///
/// ランループの**ブロック**（`__CFRunLoopDoBlocks`）はメインキューの排出とは別経路なので、
/// 排出中かどうかに関係なく実行される。**渡し先がここを通っていれば、渡した先で
/// 入れ子のランループへ入っても後続のメインキューは詰まらない。**
///
/// - Important: **終了要求をメインへ渡す口はここ 1 つだけにすること。**
///   `DispatchQueue.main.async { NSApp.terminate(nil) }` に戻すと、上の 1〜6 が
///   そのまま復活する（そして代役を使う検査は緑のままである）。
public enum MainRunLoopHop {

    /// メインのランループへ仕事を積む。**どのスレッドから呼んでもよい。**
    ///
    /// `.commonModes` へ積むのは、メニュー追跡中・モーダル中・
    /// **`.terminateLater` の入れ子のランループ中**でも走らせるためである。
    public static func perform(_ body: @escaping @Sendable @MainActor () -> Void) {
        let main = CFRunLoopGetMain()
        CFRunLoopPerformBlock(main, CFRunLoopMode.commonModes.rawValue) {
            // ランループのブロックはメインスレッドで走る。
            MainActor.assumeIsolated { body() }
        }
        // 眠っているランループを起こす。**これが無いと次のイベントまで遅れる。**
        CFRunLoopWakeUp(main)
    }
}
