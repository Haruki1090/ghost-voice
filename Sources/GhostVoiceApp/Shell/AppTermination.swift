import Foundation

/// 終了処理が待った結果。
public enum ShutdownWaitOutcome: Sendable, Equatable {
    /// 待機状態を確かめた。**この後なら落としてよい。**
    case idle
    /// 猶予が尽きた。**発話が失われうる。**
    case timedOut
}

/// 終了の段取り。**プロセスを畳む前に必ずここを通すこと。**
///
/// ⌘V を送出した直後・クリップボードを復元する前に落ちれば、テキストはどこにも残らない。
/// したがって順序に意味がある。
///
/// 1. **待機へ戻るまで待つ**（ここで先にホットキーを止めると、押しっぱなしのキーの解放が
///    二度と届かず、録音中の発話がまるごと失われる）
/// 2. ホットキーを止める（イベント列が終端し、`run()` のループが抜ける）
/// 3. `run()` の完了を待つ
///
/// > **`GhostVoiceCLI.Shutdown` と同じ段取りである。** あちらは `ShutdownGate`
/// > （`stateUpdates` の唯一の消費者が流し込む門）で速く起きるが、
/// > **アプリ側は `stateUpdates` を消費しない**——単一消費者の 1 本は HUD が使うため。
/// > そこでここでは `isBusy`（`phase` 由来。押下から最初の emit までの窓を含む）だけを見る。
/// > 待ち方が違うだけで、**権威はどちらも状態機械の `isBusy` に置いている。**
/// > 共通化するなら Core へ移すのが筋である（統括の裁定待ち）。
public enum AppTermination {

    /// 既定の猶予。**待っているのは人がキーを離すことである。**
    /// 押しっぱなしの録音は最大 120 秒続きうるが、「もう終わらせたい」という要求としては
    /// 10 秒で打ち切る（CLI と同じ値）。
    public static let defaultGrace: Duration = .seconds(10)

    /// 待機へ戻るまで待つ。**猶予を過ぎたら諦めて `.timedOut` を返す。**
    ///
    /// - Parameter poll: 照会の間隔。`isBusy` は actor への往復なので、
    ///   詰めすぎると終了処理が状態機械を叩き続けることになる。
    public static func waitUntilIdle(
        grace: Duration = AppTermination.defaultGrace,
        poll: Duration = .milliseconds(50),
        isBusy: @Sendable () async -> Bool
    ) async -> ShutdownWaitOutcome {
        let deadline = ContinuousClock.now + grace
        while true {
            if await !isBusy() { return .idle }
            if ContinuousClock.now >= deadline { return .timedOut }
            try? await Task.sleep(for: poll)
        }
    }
}
