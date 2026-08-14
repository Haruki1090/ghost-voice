import Foundation
import GhostVoiceCore

/// 終了処理が待った結果。
public enum ShutdownWaitOutcome: Sendable, Equatable {
    /// 待機状態を確かめた。**この後なら落としてよい。**
    case idle
    /// 猶予が尽きた。**発話が失われうる。**
    case timedOut
}

/// 「いま待機状態か」を状態の列から拾って覚えておく門。
///
/// **`DictationSession` の状態を外から問い合わせて済ませてはならない。**
/// `state` を読みに行くのは actor への往復であり、その間に状態は進む。
/// ここは唯一の消費者（`SessionNarration.consume`）が流し込んだものを見る。
public actor ShutdownGate {

    private var isIdle = true
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    /// 状態が変わった。**`.failed` は待機ではない**（直後に必ず `.idle` が続く）。
    public func observe(_ state: SessionState) {
        isIdle = (state == .idle)
        if isIdle { releaseWaiters() }
    }

    /// 状態の列が終端した。`DictationSession.run()` は処理中の発話を見届けてから
    /// 終端するので、ここへ来た時点で待つものは残っていない。
    public func streamFinished() {
        isIdle = true
        releaseWaiters()
    }

    /// 待機へ戻るまで待つ。**猶予を過ぎたら諦めて `.timedOut` を返す。**
    ///
    /// 永久に待たないのは、キーを押したまま終了要求が来た場合に
    /// 「二度と終われないプロセス」になるため。諦めたことは呼び出し側が表に出す。
    public func waitUntilIdle(within grace: Duration) async -> ShutdownWaitOutcome {
        if isIdle { return .idle }

        let timeout = Task { [weak self] in
            try? await Task.sleep(for: grace)
            guard !Task.isCancelled else { return }
            await self?.releaseWaiters()
        }
        defer { timeout.cancel() }

        await withCheckedContinuation { waiters.append($0) }
        // 起こされた理由は 2 つある。**どちらだったかは今の状態が示す。**
        return isIdle ? .idle : .timedOut
    }

    private func releaseWaiters() {
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

/// 終了の段取り。**`exit()` の前に必ずここを通すこと。**
///
/// Task 10 申し送り【1】: 確定〜挿入はキャンセルの効かないタスクで走るので、
/// `run()` を畳んでも発話自体は完走する。**しかし `exit()` はプロセスごと消す。**
/// ⌘V を送出した直後・クリップボードを復元する前に落ちれば、テキストはどこにも残らない
/// （Task 8 が潰した「成功と記録されるのにテキストが無い」と同じ形）。
///
/// 順序に意味がある。
///
/// 1. **待機へ戻るまで待つ。** ここで先にホットキーを止めると、押しっぱなしの
///    キーの解放が二度と届かず、録音中の発話がまるごと失われる
/// 2. ホットキーを止める（イベント列が終端し、`run()` のループが抜ける）
/// 3. `run()` の完了を待つ（`run()` は `completionTask` を見届けてから戻る）
/// 4. それでも待機でなければ、**失われたことを言う**
public enum Shutdown {

    /// 既定の猶予。挿入まで（NFR-P6）は 1 秒だが、ここが待つのは
    /// **人がキーを離すまで**を含む。押しっぱなしの録音は最大 120 秒続きうるので、
    /// 「もう終わらせたい」という要求としては 10 秒で打ち切る。
    public static let defaultGrace: Duration = .seconds(10)

    public static func perform(
        gate: ShutdownGate,
        grace: Duration = Shutdown.defaultGrace,
        stopHotkey: @Sendable () -> Void,
        awaitRun: @Sendable () async -> Void,
        finalState: @Sendable () async -> SessionState,
        writer: any ConsoleWriting
    ) async {
        writer.write("\n[終了] 進行中の発話を待っています…\n")

        if await gate.waitUntilIdle(within: grace) == .timedOut {
            writer.write("[終了] \(grace) 待っても待機へ戻りませんでした。打ち切ります。\n")
        }

        stopHotkey()
        await awaitRun()

        if await finalState() != .idle {
            writer.write("[終了] 発話の途中で終了したため、この発話は挿入されませんでした。\n")
        }
        writer.write("[終了] Ghost Voice を終了しました。\n")
    }
}
