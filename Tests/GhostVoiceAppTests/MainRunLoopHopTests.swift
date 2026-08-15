import CoreFoundation
import Foundation
import Testing

@testable import GhostVoiceApp

/// クロージャをまたいで読み書きする旗。
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Bool
    init(_ value: Bool) { stored = value }
    var value: Bool {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// **メインへの受け渡しが、メインキューの排出中でも届くこと。**
///
/// ここが崩れると `.app` は終了要求を受け取っても終わらない（`bug-term`）。
/// 実機では `SIGTERM` も `pkill` も効かず、`kill -9` しか残らなかった。
@Suite("メインへの受け渡し（MainRunLoopHop）")
struct MainRunLoopHopTests {

    /// **これがこの欠陥を捕まえる検査である。**
    ///
    /// 作る状況は `.terminateLater` の最中とまったく同じ:
    /// **メインキューのブロックを実行したまま、入れ子のランループを回している。**
    /// このとき `DispatchQueue.main.async` は 1 件も進まない
    /// （libdispatch は排出中の再入を拒む）。`MainActor` はメインキューへ積むので、
    /// この状態で `Task { @MainActor in … }` を待つ設計は永久に戻らない。
    ///
    /// `MainRunLoopHop` はランループの**ブロック**（メインキューの排出とは別経路）を使うので届く。
    /// **`DispatchQueue.main.async` に戻すとこの検査が落ちる。**
    @Test("メインキューが排出中でも、入れ子のランループの間に届く")
    func hopArrivesWhileMainQueueIsDraining() async throws {
        let hopFired = Flag(false)
        let queueFiredDuringNestedLoop = Flag(false)
        let finished = Flag(false)

        DispatchQueue.main.async {
            // ここから先は「メインキューを排出中」である。
            let queueFired = Flag(false)
            MainRunLoopHop.perform { hopFired.value = true }
            // **比較対象。** 同じことをメインキューへ積むと届かない。
            DispatchQueue.main.async { queueFired.value = true }

            // 入れ子のランループ（`.terminateLater` が回すものと同じ形）。
            // **合否線ではなく、届くのに十分な長さ**として 0.5 秒回す。
            let deadline = Date().addingTimeInterval(0.5)
            while Date() < deadline { CFRunLoopRunInMode(.defaultMode, 0.02, true) }

            queueFiredDuringNestedLoop.value = queueFired.value
            finished.value = true
        }

        // **メインを塞がずに待つ。** 塞ぐと上のブロックが走れない。
        // 上限は「戻らない実装を黙って待ち続けない」ための値であり、要件値ではない。
        let limit = ContinuousClock.now + .seconds(10)
        while !finished.value, ContinuousClock.now < limit {
            try await Task.sleep(for: .milliseconds(20))
        }

        try #require(finished.value, "メインキューが排出されていない（この検査が成立しない環境）")
        #expect(hopFired.value, "入れ子のランループの間にメインへ届かなかった（終了要求が消える）")
        // **実測の記録でもある**（2026-08-15 / M3 / macOS 26.5.2）。
        // ここが `true` に変わったら、それは OS の振る舞いが変わったということなので、
        // コードではなく `MainRunLoopHop` の注記と `docs/` を事実に合わせて直すこと。
        #expect(
            !queueFiredDuringNestedLoop.value,
            "メインキューが排出中でも進むようになった。注記と docs を事実に合わせて直すこと")
    }

    /// **どのスレッドから呼んでもよいこと。** シグナルの受け口は専用のキューに居る。
    @Test("背景のキューから呼んでもメインで走る")
    func hopWorksFromABackgroundQueue() async throws {
        let ranOnMain = Flag(false)
        let finished = Flag(false)

        DispatchQueue.global().async {
            MainRunLoopHop.perform {
                ranOnMain.value = Thread.isMainThread
                finished.value = true
            }
        }
        // 積んだブロックを走らせるためにメインのランループを回してもらう。
        DispatchQueue.main.async {
            let deadline = Date().addingTimeInterval(0.5)
            while Date() < deadline { CFRunLoopRunInMode(.defaultMode, 0.02, true) }
        }

        let limit = ContinuousClock.now + .seconds(10)
        while !finished.value, ContinuousClock.now < limit {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(finished.value, "メインへ届かなかった")
        #expect(ranOnMain.value)
    }
}
