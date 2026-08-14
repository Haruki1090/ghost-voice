import Foundation

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
/// ここは唯一の消費者（CLI の `SessionNarration.consume`）が流し込んだものを見る。
///
/// - Note: **門を持てるのは `stateUpdates` を消費している経路だけである**
///   （`AsyncStream` の消費者は 1 つに限られる）。いまそれは CLI だけであり、
///   **`.app` 側は門を持たない。** 門が無い経路は `isBusy` の照会だけで待つ。
///
///   **`.app` が門を持たない理由は「1 本を HUD が使っているから」ではない。**
///   HUD が読むのは分配器（`DictationSession.stateStream()`。呼ぶたびに独立した
///   ストリームを返す）であり、**`.app` では `stateUpdates` の読み手が 1 人も居ない。**
///   空いてはいるが、**終了の判定に使ってはならない**——`stateUpdates` を読み始めると
///   HUD と同じ状態を 2 系統で追うことになり、しかも**分配器の側は読み手が遅れると
///   古いものから捨てる**（`SessionBroadcast` の注記）ので、どちらで待っても
///   `.idle` を取りこぼしうる。**権威は状態機械の `isBusy` に置く**（下の `waitUntilIdle`）。
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

/// 終了のときに利用者へ伝える事実。
///
/// **文言をここに 1 つだけ持つ。** CLI と `.app` で別々に書き直されると、
/// 「利用者が何を待たれているか判る文言」という**実機で失った発話から学んだ性質**が
/// 片側だけ失われる（そして両方とも自分のテストでは緑になる）。
///
/// - Note: **前後の余白と改行は出力先が決める。** 端末は行末に改行が要り、
///   `.app` の診断出力（`AppDiagnostics.note`）は自分で改行を足す。
///   ここが持つのは**文言そのものだけ**である。
public enum ShutdownAnnouncement: Sendable, Equatable {
    /// 待ち始めた。**待っている相手は人である。**
    case waiting(grace: Duration)
    /// 猶予が尽きた。
    case gaveUp(grace: Duration)
    /// 発話を抱えたまま終わる。**失われたことを言う。**
    case utteranceLost
    /// 終了した。
    case finished

    public var text: String {
        switch self {
        case .waiting(let grace):
            // **待っている相手が人であることを言う。**
            // 「待っています…」だけだと、利用者は何が起きるのを待たれているのか判らない。
            // 実機の初回で、PTT キーを押したまま喋り続けて猶予が尽き、**発話が失われた**
            // （この経路の動作自体は設計どおりで、失われたことも正直に言っていた。
            // 足りなかったのは**利用者が取るべき行動**である）。
            """
            [終了] 進行中の発話を待っています…
                   **録音中なら PTT キーを離してください。** 離せば確定・整形・挿入まで走ります。
                   \(grace) 待っても待機へ戻らなければ、その発話は失われます。
            """
        case .gaveUp(let grace):
            "[終了] \(grace) 待っても待機へ戻りませんでした。打ち切ります。"
        case .utteranceLost:
            "[終了] 発話の途中で終了したため、この発話は挿入されませんでした。"
        case .finished:
            "[終了] Ghost Voice を終了しました。"
        }
    }
}

/// 終了の段取り。**プロセスを畳む前に必ずここを通すこと。**
///
/// **CLI と `.app` はここを共有する。** 段取りが 2 箇所にあると必ずずれ、
/// ずれたことに誰も気づけない（両方とも自分のテストでは緑になる）。
///
/// 確定〜挿入はキャンセルの効かないタスクで走るので、`run()` を畳んでも発話自体は
/// 完走する。**しかしプロセスを消すのは別である。**
/// ⌘V を送出した直後・クリップボードを復元する前に落ちれば、テキストはどこにも残らない
/// （フェーズ 1 が潰した「成功と記録されるのにテキストが無い」と同じ形）。
///
/// 順序に意味がある。
///
/// 1. **待機へ戻るまで待つ。** ここで先にホットキーを止めると、押しっぱなしの
///    キーの解放が二度と届かず、録音中の発話がまるごと失われる
/// 2. ホットキーを止める（イベント列が終端し、`run()` のループが抜ける）
/// 3. `run()` の完了を待つ（`run()` は `completionTask` を見届けてから戻る）
/// 4. それでも待機でなければ、**失われたことを言う**
///
/// - Important: **`perform` が戻る前にプロセスを落としてはならない。**
///   `stopHotkey()` は自分でメインのランループからソースを外すので、
///   そこがもう 1 つの出口になりかける。`exit()` の入口は
///   **`perform` を待った後の 1 箇所だけ**にすること。
public enum Shutdown {

    /// 既定の猶予。テキストが出るまで（NFR-P6a）は 1 秒だが、ここが待つのは
    /// **人がキーを離すまで**を含む。押しっぱなしの録音は最大 120 秒続きうるので、
    /// 「もう終わらせたい」という要求としては 10 秒で打ち切る。
    public static let defaultGrace: Duration = .seconds(10)

    /// 門を 1 回どれだけ待つか。**猶予そのものを渡さない**——
    /// 門が待機を指しても状態機械が処理中でありうるので、こまめに起きて確認する。
    static let gateWindow: Duration = .milliseconds(100)

    /// 待機へ戻るまで待つ。**猶予を過ぎたら諦めて `.timedOut` を返す。**
    ///
    /// **権威は状態機械の `isBusy` に置く。**
    ///
    /// 門が拾うのは `stateUpdates` の列で、状態機械の内部状態はそれより先に変わる。
    /// **押下の直後に終了要求が来ると、門はまだ「待機」に見える**——そこで
    /// ホットキーを止めると、キー解放が二度と届かず**その発話が丸ごと消える。**
    /// （実測: 負荷を掛けて `swift test` を回すと `shutdownWaitsForKeyRelease` が
    /// 実際に落ちた。門だけを見ていたときの窓である。）
    /// したがって門は「速く起きるための道具」として使い、起きたあとに状態機械へ確認する。
    ///
    /// **確認するのは `state`（最後に emit した状態）ではなく `phase` 由来の
    /// `isBusy` である。** `state` は emit でしか変わらないので、押下を受けてから
    /// 最初の emit までの窓を「待機」と読み違える。
    ///
    /// **窓の長さは `begin()` の費用そのものである。** 起動後の最初の 1 発話が
    /// 44〜540 ms 掛かっていた件は、フェーズ 2 で起動時に解析器を 1 往復させて
    /// 捨てることで吸収した（詳細設計書 §10）。**現在の窓は定常時の 1.2〜1.4 ms
    /// に縮んでいるが、窓が消えたわけではないのでこの読み替えは今も要る。**
    ///
    /// - Parameters:
    ///   - gate: `stateUpdates` を消費している経路だけが渡せる。`nil` なら `isBusy` だけで待つ。
    ///   - poll: 照会の間隔。`isBusy` は actor への往復なので、詰めすぎると
    ///     終了処理が状態機械を叩き続けることになる。
    public static func waitUntilIdle(
        gate: ShutdownGate? = nil,
        grace: Duration = Shutdown.defaultGrace,
        poll: Duration = .milliseconds(50),
        isBusy: @Sendable () async -> Bool
    ) async -> ShutdownWaitOutcome {
        let deadline = ContinuousClock.now + grace
        while true {
            if let gate {
                if await gate.waitUntilIdle(within: gateWindow) == .idle, await !isBusy() {
                    return .idle
                }
            } else if await !isBusy() {
                return .idle
            }
            if ContinuousClock.now >= deadline { return .timedOut }
            // 門が既に待機を指しているのに状態機械が処理中の場合、上の待ちは即座に
            // 戻る。空回りを避けるために少しだけ眠る（終了処理でしか通らない経路）。
            try? await Task.sleep(for: poll)
        }
    }

    /// 終了の段取りを通す。**呼び出し側はこれが戻るまでプロセスを落としてはならない。**
    ///
    /// - Parameter announce: 文言の出力先。**文言そのものは渡さない**
    ///   （`ShutdownAnnouncement` が持つ）。ここが決めるのは前後の余白と送り先だけである。
    public static func perform(
        gate: ShutdownGate? = nil,
        grace: Duration = Shutdown.defaultGrace,
        poll: Duration = .milliseconds(50),
        stopHotkey: @Sendable () -> Void,
        awaitRun: @Sendable () async -> Void,
        isBusy: @Sendable () async -> Bool,
        announce: @Sendable (ShutdownAnnouncement) -> Void
    ) async {
        announce(.waiting(grace: grace))

        if await waitUntilIdle(gate: gate, grace: grace, poll: poll, isBusy: isBusy) == .timedOut {
            announce(.gaveUp(grace: grace))
        }

        stopHotkey()
        await awaitRun()

        if await isBusy() { announce(.utteranceLost) }
        announce(.finished)
    }
}
