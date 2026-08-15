import Foundation
import GhostVoiceCore

/// 終了のときに段取りを通す相手。
///
/// **器（`GhostVoiceAppDelegate`）は本物のセッションを名指ししない。**
/// 名指しすると、`.terminateLater` を返す経路が**実発話でしか通らなく**なり、
/// 「終了要求が効くか」を実バンドルで一度も測れない
/// （実機で 17 分止まったままの `.app` を見つけるまで、実際にそうだった）。
@MainActor
public protocol AppShutdownPerforming: AnyObject {
    /// 待機へ戻るまで待ってから畳む。**これが戻るまでプロセスを落としてはならない。**
    func shutdown() async
}

/// 終了の素振り（`--shutdown-check`）。**マイクにもキー監視にも触らない。**
///
/// ## 何のためにあるのか
///
/// V-34（発話の途中の終了要求で発話が失われないか）は、**本物の発話を抱えていないと
/// 通らない経路**だった。そのため実バンドルでは一度も測られておらず、
/// 「`SIGTERM` で終わらない」という欠陥が**代役の検査が全部緑のまま**残った。
///
/// ここは本物の発話の代わりに「**N 秒のあいだ処理中を名乗る**」だけの相手を置く。
/// 通る段取りは本物とまったく同じ `GhostVoiceCore.Shutdown.perform` であり、
/// 器から見た形（`.terminateLater` を返して待つ）も本物と区別がつかない。
///
/// - Important: **製品の機能ではない。** `--shutdown-check` は
///   `--hud-check` / `--window-check` と同じ「確かめるための入口」である。
///   セッションを作らないので TCC のダイアログが出る余地が無い。
@MainActor
public final class ShutdownRehearsal: AppShutdownPerforming {

    /// クロージャをまたいで読み書きする旗。**`Shutdown.perform` の引数は非分離である。**
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var stored = false
        var value: Bool {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }

    /// どれだけ「処理中」を名乗るか。**本物の発話（確定〜整形〜挿入）の代わりである。**
    ///
    /// **数え始めるのは終了要求が来た時点である**（起動時点ではない）。
    /// 起動から数えると、素振りを走らせる側が「何秒後に要求を送るか」で結果が変わり、
    /// **待ちが効いていないのに緑に見える。** ここが測りたいのは
    /// 「要求が来たとき発話を抱えていたら、最後まで見届けるか」である。
    private let busyFor: Duration
    private let hotkeyStopped = Flag()
    private let utteranceDelivered = Flag()
    /// 本物の `DictationSession.run()` と同じ形——**ホットキーが止まるまで戻らない。**
    private var runTask: Task<Void, Never>?
    private var didShutDown = false

    /// - Parameter busyFor: 「発話を抱えている」ことにする長さ。
    public init(busyFor: Duration) {
        self.busyFor = busyFor
        let stopped = hotkeyStopped
        let delivered = utteranceDelivered
        runTask = Task {
            // **止められるまで戻らない。** ここを先に畳むと、本物では
            // 「押しっぱなしのキーの解放が二度と届かない」＝発話が丸ごと消える。
            while !stopped.value { try? await Task.sleep(for: .milliseconds(10)) }
            delivered.value = true
            AppDiagnostics.note("[素振り] run() が戻りました（＝抱えていた発話を最後まで届けた）。")
        }
    }

    /// 素振りが「発話を届けた」ところまで進んだか。**検査が読む。**
    public var didDeliverUtterance: Bool { utteranceDelivered.value }

    public func shutdown() async {
        await shutdown(grace: Shutdown.defaultGrace)
    }

    /// - Note: **本物（`AppSessionRuntime.shutdown`）と同じ 1 つの段取りを通す。**
    ///   ここが別の順序を持つと、素振りが緑でも本物が壊れる。
    public func shutdown(grace: Duration) async {
        guard !didShutDown else { return }
        didShutDown = true

        // **ここが「発話を抱えたまま終了要求を受けた」瞬間である。**
        let busyUntil = ContinuousClock.now + busyFor
        let stopped = hotkeyStopped
        let runTask = self.runTask
        await Shutdown.perform(
            grace: grace,
            stopHotkey: { stopped.value = true },
            awaitRun: { await runTask?.value },
            isBusy: { ContinuousClock.now < busyUntil },
            announce: { AppDiagnostics.note($0.text) })
    }
}
