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

/// **終了で打ち切った発話が、いまどこにあるか。**
///
/// 「挿入されませんでした」だけでは足りない——**どこにも無いのか、履歴にはあるのかで
/// 利用者が次にすることが変わる**（実機 2026-08-15: 猶予切れで打ち切った発話が
/// 欄にもクリップボードにも履歴にも残っていなかった）。
public enum ShutdownSalvage: Sendable, Equatable {
    /// 抱えていた発話は無かった。**打ち切っていない。**
    case nothingHeld
    /// **そのときのテキストを履歴へ残した。** 挿入はしていない。
    ///
    /// - Parameter provisional: 確定していないテキスト（暫定結果）か。
    ///   録音中に打ち切った場合は必ず真である。
    case retainedInHistory(provisional: Bool)
    /// **どこにも残せなかった。** 履歴へも書けていない。
    case lost
    /// secure input が有効だったので、**意図して残していない**
    /// （基本設計書 §7 / 要件定義書 FR-4 の唯一の例外）。
    case refusedSecureInput
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
/// - Important: **`Duration` を素で補間してはならない。** `"\(Duration.seconds(10))"` は
///   `10.0 seconds` である。実機のログに実際にこれが出た（2026-08-15）。
///   長さは必ず `JapaneseDuration` を通すこと。
public enum ShutdownAnnouncement: Sendable, Equatable {
    /// 待ち始めた。**待っている相手は人である。**
    case waiting(grace: Duration)
    /// **まだ待っている。** 猶予が尽きるまで一定間隔で繰り返す（`Shutdown.heartbeat`）。
    ///
    /// これがあるのは 2 つの理由による。
    ///
    /// 1. **HUD に残り時間を出すため。** 静止した文言だと「待っている」と「固まった」を
    ///    区別できない。**このプロジェクトが直したばかりの欠陥がまさにそれである**
    ///    （メインキューが詰まって HUD が死んでいたのに、誰も気づけなかった）
    /// 2. **HUD が死んでいてもログには残り続けるため。** 終了待ちは HUD が死んだ
    ///    状況でも起きる。片方だけに頼らない
    case stillWaiting(remaining: Duration)
    /// 猶予が尽きた。
    case gaveUp(grace: Duration)
    /// **発話を抱えたまま終わる。** 抱えていたものがどこへ行ったかまで言う。
    case utteranceInterrupted(ShutdownSalvage)
    /// 終了した。
    case finished

    /// ログ・端末へ出す文言。**改行を含みうる。**
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
                   \(JapaneseDuration.text(grace)) 待っても待機へ戻らなければ、打ち切って履歴へ残します。
            """
        case .stillWaiting(let remaining):
            "[終了] まだ待っています。**PTT キーを離してください。**（残り \(JapaneseDuration.text(remaining))）"
        case .gaveUp(let grace):
            "[終了] \(JapaneseDuration.text(grace)) 待っても待機へ戻りませんでした。打ち切ります。"
        case .utteranceInterrupted(let salvage):
            switch salvage {
            case .nothingHeld:
                // ここへは来ない（`perform` が `.nothingHeld` では告げない）。
                // それでも文言を持つのは、表に穴を空けないためである。
                "[終了] 抱えている発話はありませんでした。"
            case .retainedInHistory(let provisional):
                provisional
                    ? "[終了] 発話の途中で終了しました。挿入はしていませんが、"
                        + "**そこまでの暫定テキスト（確定前）を履歴へ残しました。** 履歴画面から取り出せます。"
                    : "[終了] 発話の途中で終了しました。挿入はしていませんが、"
                        + "**そのテキストを履歴へ残しました。** 履歴画面から取り出せます。"
            case .lost:
                "[終了] 発話の途中で終了し、**そのテキストをどこにも残せませんでした**（履歴へも書けていません）。"
            case .refusedSecureInput:
                "[終了] パスワード入力中（secure input）だったため、この発話は残していません。"
            }
        case .finished:
            "[終了] Ghost Voice を終了しました。"
        }
    }

    /// **HUD の帯に出す 1 行。** 改行を含まない。
    ///
    /// - Returns: **nil は「HUD には出さない」。** 出さないものが 2 つある。
    ///
    ///   - `.waiting`: **待機中に終了要求が来ると 0.13 秒で終わる**（実測 V-34）。
    ///     そこで出すと一瞬光って消えるだけで、「何か起きた」という不安しか残さない。
    ///     **本当に待つことになったときにだけ出す**——それが `.stillWaiting` であり、
    ///     最初の 1 件は 1 秒後に来る（`Shutdown.heartbeat`）。
    ///     **これは決めごとであって実測ではない。**
    ///   - `.finished`: この直後にプロセスが消えるので、出しても読む時間が無い。
    ///
    /// - Note: **`.app` の HUD は `.idle` のとき非表示という規則を持つが、
    ///   終了待ちはその規則より優先する。** 規則の目的は「発話が無いときに邪魔をしない」
    ///   ことであり、終了待ちは発話の有無に関わらず**利用者の行動（キーを離す）を
    ///   待っている**。待たれていることが見えないまま猶予を使い切ったのが元の欠陥である。
    public var hudText: String? {
        switch self {
        case .waiting: nil
        case .stillWaiting(let remaining):
            "終了待ち: PTT キーを離してください（残り \(JapaneseDuration.text(remaining))）"
        case .gaveUp: "終了待ちを打ち切りました。"
        case .utteranceInterrupted(let salvage):
            switch salvage {
            case .nothingHeld: nil
            case .retainedInHistory(let provisional):
                provisional
                    ? "途中で終了しました。暫定テキストを履歴に残しました。"
                    : "途中で終了しました。テキストを履歴に残しました。"
            case .lost: "途中で終了し、テキストをどこにも残せませんでした。"
            case .refusedSecureInput: "パスワード入力中だったため、発話は残していません。"
            }
        case .finished: nil
        }
    }

    /// 表示の強さ。**具体的な色と秒数は媒体が決める**（`SessionNoticeAnnouncement` と同じ規律）。
    ///
    /// - Note: **終了待ちは失敗ではない。** 正しく待っている最中であり、赤く出すと
    ///   「壊れた」と読まれる——**この欠陥の症状そのものである**
    ///   （利用者は正しく待っているアプリを見て「全然反応しません」と言った）。
    ///   利用者が行動を取れば解決するので `.actionRequired` に置く。
    public var weight: SessionNoticeAnnouncement.Weight {
        switch self {
        case .waiting, .stillWaiting: .actionRequired
        case .gaveUp: .warning
        case .utteranceInterrupted(let salvage):
            switch salvage {
            case .nothingHeld: .info
            // **履歴に残っているなら「失った」ではない。** 取り出す先があることを
            // 告げるのが目的で、赤く出すと「消えた」と読まれる。
            case .retainedInHistory: .actionRequired
            case .lost: .lost
            case .refusedSecureInput: .info
            }
        case .finished: .info
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

    /// 既定の猶予。**決めごとであって実測ではない。**
    ///
    /// テキストが出るまで（NFR-P6a）は 1 秒だが、ここが待つのは
    /// **人がキーを離すまで**を含む。押しっぱなしの録音は最大 120 秒続きうるので、
    /// 「もう終わらせたい」という要求としては 10 秒で打ち切る。
    ///
    /// **この値を延ばして発話を守ろうとしてはならない。** 猶予をどれだけ延ばしても
    /// 「終わらないプロセス」に近づくだけで、押しっぱなしの利用者は必ず追い越す
    /// （実機 2026-08-15: 利用者は 10 秒を丸ごと使い切った）。**守りは打ち切りの側に置く**
    /// ——打ち切るときにそこまでのテキストを履歴へ残す（`DictationSession` の salvage）。
    public static let defaultGrace: Duration = .seconds(10)

    /// 待っている間、どれだけの間隔で「まだ待っている」と言うか。
    /// **決めごとであって実測ではない。**
    ///
    /// 1 秒ごとに言うのは、**残り時間が動いていること自体が「生きている」の証拠**だからである。
    /// 静止した文言では「待っている」と「固まった」を区別できない。
    public static let heartbeat: Duration = .seconds(1)

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
    ///   - onHeartbeat: **まだ待っていることを一定間隔で知らせる口。** 引数は残りの猶予
    ///     （`heartbeat` の刻みへ丸めてある）。ここが動き続けることが「固まっていない」の
    ///     唯一の証拠になるので、**HUD にもログにも同じものを流すこと。**
    public static func waitUntilIdle(
        gate: ShutdownGate? = nil,
        grace: Duration = Shutdown.defaultGrace,
        poll: Duration = .milliseconds(50),
        heartbeat: Duration = Shutdown.heartbeat,
        onHeartbeat: (@Sendable (Duration) -> Void)? = nil,
        isBusy: @Sendable () async -> Bool
    ) async -> ShutdownWaitOutcome {
        let started = ContinuousClock.now
        let deadline = started + grace
        var beats = 0
        while true {
            if let gate {
                if await gate.waitUntilIdle(within: gateWindow) == .idle, await !isBusy() {
                    return .idle
                }
            } else if await !isBusy() {
                return .idle
            }
            let now = ContinuousClock.now
            if now >= deadline { return .timedOut }
            if let onHeartbeat, heartbeat > .zero {
                // **経過から刻みの数を出す。** 前回からの差で数えると、
                // 眠りが伸びた回に刻みが 1 つ飛ぶ（＝残り時間が 2 秒ずつ減る）。
                let elapsed = now - started
                let due = Int(JapaneseDuration.seconds(elapsed) / JapaneseDuration.seconds(heartbeat))
                if due > beats {
                    beats = due
                    // **残りは刻みへ丸める。** 「残り 8.94 秒」は読み手の役に立たない。
                    let remaining = grace - heartbeat * beats
                    onHeartbeat(remaining > .zero ? remaining : .zero)
                }
            }
            // 門が既に待機を指しているのに状態機械が処理中の場合、上の待ちは即座に
            // 戻る。空回りを避けるために少しだけ眠る（終了処理でしか通らない経路）。
            try? await Task.sleep(for: poll)
        }
    }

    /// 終了の段取りを通す。**呼び出し側はこれが戻るまでプロセスを落としてはならない。**
    ///
    /// - Parameter announce: 文言の出力先。**文言そのものは渡さない**
    ///   （`ShutdownAnnouncement` が持つ）。ここが決めるのは前後の余白と送り先だけである。
    /// - Parameter salvage: **打ち切った発話がどこへ行ったかを尋ねる口。**
    ///   `awaitRun()` が戻った後に 1 度だけ呼ぶ（救出は `run()` の中で起きる）。
    ///
    ///   **nil を渡してよいのは、救出の仕組みを持たない相手だけである**（素振りなど）。
    ///   その場合は `isBusy` で「まだ抱えている」を見て `.lost` として告げる——
    ///   救出できたかを知らないのに「履歴にあります」と言うほうが害が大きい。
    public static func perform(
        gate: ShutdownGate? = nil,
        grace: Duration = Shutdown.defaultGrace,
        poll: Duration = .milliseconds(50),
        stopHotkey: @Sendable () -> Void,
        awaitRun: @Sendable () async -> Void,
        isBusy: @Sendable () async -> Bool,
        salvage: (@Sendable () async -> ShutdownSalvage)? = nil,
        // **`@escaping` が要る。** 待っている間の「まだ待っています」を
        // `waitUntilIdle` へ渡すクロージャの中から呼ぶためである。
        announce: @escaping @Sendable (ShutdownAnnouncement) -> Void
    ) async {
        announce(.waiting(grace: grace))

        let outcome = await waitUntilIdle(
            gate: gate, grace: grace, poll: poll,
            onHeartbeat: { announce(.stillWaiting(remaining: $0)) },
            isBusy: isBusy)
        if outcome == .timedOut { announce(.gaveUp(grace: grace)) }

        stopHotkey()
        await awaitRun()

        // **打ち切った発話の行き先を必ず告げる。**
        // 「挿入されませんでした」だけでは、どこにも無いのか履歴にはあるのかが判らず、
        // 利用者は次に何をすればよいか決められない（実機 2026-08-15）。
        let where_: ShutdownSalvage
        if let salvage {
            where_ = await salvage()
        } else {
            where_ = await isBusy() ? .lost : .nothingHeld
        }
        if where_ != .nothingHeld { announce(.utteranceInterrupted(where_)) }
        announce(.finished)
    }
}
