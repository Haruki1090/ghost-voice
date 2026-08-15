import Foundation
import GhostVoiceCore

/// HUD へ届く出来事。
public enum HUDEvent: Sendable, Equatable {
    case state(SessionState)
    case level(Float)
    case notice(SessionNotice)
    case installation(AssetInstallationEvent)
    /// **時間が来ただけ**（保持の期限・間引きの解除）。`HUDPresenter` が返した時刻に起こす。
    case tick
}

/// **状態の並びを「いま何を出すか」へ翻訳する。純粋な値の変換で、描画も時計も持たない。**
///
/// ## なぜ状態をそのまま描かないか（この型が存在する理由）
///
/// 1. **`.failed` の直後には必ず `.idle` が続く。** `DictationSession.fail()` が同期で
///    両方を emit するので、状態を素直に描くと**エラーは 1 フレームも見えない。**
///    → **保持の時間は HUD が自分で持つ**（`Timing.failure` / `Timing.speechLost`）。
/// 2. **完了のチェックマークは状態ではない。** `.inserting` → `.idle` の間に挟む見せ方である。
/// 3. **暫定テキストは `.volatile` 更新のたびに届く。** 長い発話では数百件になる。
///    素通しすると描画がその回数だけ走る。**メインスレッドを塞ぐと `CGEventTap` の配送が
///    p50 0.045 ms → 12.8 ms へ悪化する**（ランループ検証の実測）ので、
///    **`Timing.minimumVolatileInterval` で間引く。**
///
/// ## 間引きの規律（**捨てるのは中身であって、変わり目ではない**）
///
/// - **状態の変わり目（`.recording` へ入る／出る、`.failed`、`.idle`）は必ず即座に反映する。**
///   ここを間引くと「録音していないのに録音表示が残る」ことが起きる。
/// - 間引くのは**録音中の中身の更新だけ**（暫定テキストと音量）。
/// - **最後の 1 件は必ず出す**（末尾を保留したまま捨てない）。
///   保留があるあいだは `apply` が起こし直す時刻を返す。
///
/// ## 使い方
///
/// ```swift
/// var presenter = HUDPresenter(languageBadge: "日")
/// let wake = presenter.apply(.state(.recording(volatileText: "こんにちは")), at: .now)
/// // wake が非 nil なら、その時刻に `.tick` を渡し直す
/// ```
public struct HUDPresenter: Sendable {

    /// 表示の時間。**どれも要件値ではない**（要件は「数秒表示する」としか言っていない）。
    public struct Timing: Sendable, Equatable {
        /// 完了のチェックマーク（詳細設計書 §7.4 の「0.6 秒」）。
        public var completion: Duration = .milliseconds(600)
        /// エラーの表示（同 §7.4 の「3 秒」）。
        public var failure: Duration = .seconds(3)
        /// **発話を失った疑いがあるときだけ長く出す。**
        /// 毎回強く出すと本当に失った回が埋もれる（`SessionFailureNotice.speechWasLost`）。
        public var speechLost: Duration = .seconds(8)
        /// 通知（Undo の顛末など）の表示。
        public var notice: Duration = .seconds(2)
        /// **録音中の中身を更新する最短の間隔。**
        ///
        /// 50 ms = 最大 20 回/秒。**これは要件値ではない。**
        /// 音量は実測 10 回/秒（タップ長 100 ms）でしか来ないので、
        /// この間引きが実際に効くのは暫定テキストが密に届く区間だけである。
        public var minimumVolatileInterval: Duration = .milliseconds(50)

        public init() {}
    }

    /// いま出すもの。
    public private(set) var display: HUDDisplay = .hidden

    /// 認識言語のバッジ。**発話の合間に呼び手が入れ替える**（設定は再起動なしに変わりうる）。
    public var languageBadge: String

    public var timing: Timing

    /// 直近の音量。**録音していない間は流れてこない**ので、`.idle` で 0 に戻す。
    private var level: Float = 0
    /// 保持の期限。nil なら保持していない。
    private var holdUntil: ContinuousClock.Instant?
    /// **時間で畳まない表示を出しているか。**
    ///
    /// 2 つある。どちらも「いつ消えてよいかを時計では決められない」ものである。
    ///
    /// 1. **モデルの導入中**（数分掛かる。数秒で消すと「押しても何も起きない」へ戻る）
    /// 2. **`.undoCopiedRawTextToClipboard`**（`SessionNoticeAnnouncement.isPersistent`。
    ///    読み落とすとクリップボードに在る生テキストへ辿り着けない）
    ///
    /// **`holdUntil` を nil にするだけでは足りない。** 直後に必ず来る `.idle` が
    /// 「貼り付いた表示を畳む」側へ落ちて消してしまう。
    private var holdsIndefinitely = false
    /// **終了待ちを出している期限。** ここまでは何が届いても譲らない。
    ///
    /// `holdUntil` では足りない——**`.recording` は保持中のどんな表示にも勝つ**ので、
    /// 押しっぱなしで喋っている最中（＝この告知がいちばん要る場面）に、
    /// 次の暫定テキストが 50 ms で上書きしてしまう。
    private var shutdownUntil: ContinuousClock.Instant?

    /// 間引きで保留している録音中の中身。
    private var pendingRecording: HUDRecording?
    /// 最後に録音中の中身を反映した時刻。
    private var lastRecordingCommit: ContinuousClock.Instant?

    public init(languageBadge: String, timing: Timing = Timing()) {
        self.languageBadge = languageBadge
        self.timing = timing
    }

    /// 出来事を 1 件反映する。
    ///
    /// - Returns: **起こし直してほしい時刻。** nil なら待つものは無い。
    ///   呼び手はこの時刻に `.tick` を渡すこと（渡さないと、保持したエラーが消えず、
    ///   保留した暫定テキストの最後の 1 件が出ない）。
    @discardableResult
    public mutating func apply(_ event: HUDEvent, at now: ContinuousClock.Instant)
        -> ContinuousClock.Instant?
    {
        // **終了待ちを出している間は、どんな出来事にも譲らない。**
        // ここが要るのは、まさに譲ってはいけない場面でだけ届く出来事があるためである
        // ——押しっぱなしで喋っている最中の `.recording` は 50 ms ごとに届き、
        // 「保持中のどんな表示にも勝つ」ので、告知は一瞬で消える。
        if let until = shutdownUntil {
            if now < until { return nextWakeup(after: now) }
            shutdownUntil = nil
        }
        switch event {
        case .state(let state): applyState(state, at: now)
        case .level(let value): applyLevel(value, at: now)
        case .notice(let notice): applyNotice(notice, at: now)
        case .installation(let installation): applyInstallation(installation, at: now)
        case .tick: break
        }
        flushPendingIfDue(at: now)
        expireHoldIfDue(at: now)
        return nextWakeup(after: now)
    }

    /// **発話に由来しないことを告げる**（起動時にキー監視を開始できなかった、など）。
    ///
    /// 状態の並びとは無関係なので、`apply` の状態機械を通さずに直接置く。
    /// **次の発話が始まれば消える**（`.recording` は保持中のどんな表示にも勝つ）。
    ///
    /// - Returns: 起こし直してほしい時刻。
    @discardableResult
    public mutating func announce(
        _ message: HUDMessage, hold: Duration, at now: ContinuousClock.Instant
    ) -> ContinuousClock.Instant? {
        pendingRecording = nil
        display = .message(message)
        holdUntil = now + hold
        holdsIndefinitely = false
        return nextWakeup(after: now)
    }

    /// **終了待ちを告げる**（`GhostVoiceCore.ShutdownAnnouncement`）。
    ///
    /// `announce(_:hold:at:)` と分けてあるのは、**譲らない期間を持つから**である。
    /// 終了待ちがいちばん要るのは「PTT キーを押したまま喋っている」場面で、
    /// そこでは `.recording` が 50 ms ごとに届く。ふつうの告知だと即座に消える。
    ///
    /// **文言も重さも Core が決める。** ここが決めるのは色と長さだけである。
    ///
    /// - Parameter hold: 譲らない長さ。次の「まだ待っています」が来るまでを覆えばよい。
    /// - Returns: 起こし直してほしい時刻。
    @discardableResult
    public mutating func announceShutdown(
        _ message: HUDMessage, hold: Duration, at now: ContinuousClock.Instant
    ) -> ContinuousClock.Instant? {
        pendingRecording = nil
        level = 0
        display = .message(message)
        shutdownUntil = now + hold
        holdUntil = now + hold
        holdsIndefinitely = false
        return nextWakeup(after: now)
    }

    // MARK: - 状態

    private mutating func applyState(_ state: SessionState, at now: ContinuousClock.Instant) {
        switch state {
        case .recording(let volatileText):
            // **新しい発話は、保持中のどんな表示にも勝つ。**
            // 利用者が話し始めているのに前のエラーを出し続けるのは嘘である。
            // **時間で畳まない表示も、ここでは畳む**（「時計で消すな」であって
            // 「次の発話にも居座れ」ではない。`SessionNoticeAnnouncement.isPersistent`）。
            holdUntil = nil
            holdsIndefinitely = false
            let recording = HUDRecording(
                level: level, languageBadge: languageBadge, volatileText: volatileText)
            if case .recording = display {
                stage(recording, at: now)  // 中身の更新 → 間引く
            } else {
                commit(recording, at: now)  // 変わり目 → 即座に
            }

        case .finalizing:
            show(.processing(.finalizing))
        case .refining:
            show(.processing(.refining))
        case .inserting:
            show(.processing(.inserting))
        case .revising:
            show(.processing(.revising))

        case .failed(let failure):
            let notice = SessionFailureNotice(failure)
            pendingRecording = nil
            level = 0
            display = .message(
                HUDMessage(
                    text: notice.summary,
                    severity: notice.speechWasLost
                        ? .lost : (notice.isRefusal ? .refusal : .warning)))
            // **`.failed` の直後には必ず `.idle` が続く**ので、ここで期限を持たないと消える。
            holdUntil = now + (notice.speechWasLost ? timing.speechLost : timing.failure)
            holdsIndefinitely = false

        case .idle:
            pendingRecording = nil
            // **音量は録音が終わっても「無音の 0」が流れてこない**（`levelStream()` の注記）。
            // ここで落とさないとインジケータが振れたまま止まる。
            level = 0
            // 保持中（エラーの直後の `.idle` がこれ）なら何も変えない。
            // **時間で畳まない表示も保持中である**（導入の進捗・クリップボードへの退避）。
            guard holdUntil == nil, !holdsIndefinitely else { return }
            if display == .processing(.inserting) {
                // **挿入が終わった。** ここだけがチェックマークを出す入口である。
                display = .completed
                holdUntil = now + timing.completion
            } else if case .message = display {
                // 導入中などの貼り付いた表示。**`.idle` で畳む。**
                display = .hidden
            } else {
                // 中断・認識なし・差し替えの終わり。**チェックマークは出さない。**
                display = .hidden
            }
        }
    }

    private mutating func show(_ next: HUDDisplay) {
        holdUntil = nil
        holdsIndefinitely = false
        pendingRecording = nil
        display = next
    }

    // MARK: - 音量

    private mutating func applyLevel(_ value: Float, at now: ContinuousClock.Instant) {
        level = value
        guard case .recording(let current) = display else {
            // 録音表示でないときは覚えるだけ。**状態の側が表示を決める。**
            return
        }
        stage(
            HUDRecording(
                level: value, languageBadge: current.languageBadge,
                volatileText: current.volatileText),
            at: now)
    }

    // MARK: - 通知

    private mutating func applyNotice(_ notice: SessionNotice, at now: ContinuousClock.Instant) {
        // **文言も「出すか出さないか」も Core が持つ**（`SessionNoticeAnnouncement`）。
        // ここがするのは、重さを HUD の見せ方（色・保持時間）へ写すことだけである。
        guard let announcement = SessionNoticeAnnouncement(notice) else { return }
        let severity = HUDPresenter.severity(for: announcement.weight)

        // **喪失の疑いだけは何を差し置いても出す**（R-9。回収を促す必要がある）。
        if severity != .lost {
            // 話している最中に割り込まない。
            if case .recording = display { return }
            // 既に「失われたかもしれない」を出しているなら上書きしない。
            if case .message(let current) = display, current.severity == .lost,
                holdUntil != nil || holdsIndefinitely
            {
                return
            }
        }

        pendingRecording = nil
        display = .message(HUDMessage(text: announcement.summary, severity: severity))
        if announcement.isPersistent {
            // **時間で畳まない**（`SessionNoticeAnnouncement.isPersistent`）。
            // 読み落とすとクリップボードに在る生テキストへ辿り着けない。
            holdUntil = nil
            holdsIndefinitely = true
        } else {
            holdUntil = now + HUDPresenter.hold(for: announcement.weight, timing: timing)
            holdsIndefinitely = false
        }
    }

    /// Core の重さを HUD の色へ。
    ///
    /// **`.actionRequired` は `.info` にする。** クリップボードへの退避は縮退が
    /// 正しく働いた結果であり、赤く出すと「発話を失った」と読まれる
    /// （`SessionNoticeAnnouncement.isFailure` が偽であることと同じ判断）。
    static func severity(for weight: SessionNoticeAnnouncement.Weight) -> HUDSeverity {
        switch weight {
        case .info, .actionRequired: .info
        case .warning: .warning
        case .lost: .lost
        }
    }

    /// Core の重さを HUD の保持時間へ。**秒数は媒体の関心である。**
    static func hold(for weight: SessionNoticeAnnouncement.Weight, timing: Timing) -> Duration {
        switch weight {
        case .info: timing.notice
        case .warning: timing.failure
        case .lost: timing.speechLost
        // ここへは来ない（`.actionRequired` は `isPersistent` なので畳まない）。
        // それでも値を返すのは、保持時間の表に穴を空けないためである。
        case .actionRequired: timing.speechLost
        }
    }

    // MARK: - モデルの導入

    /// **数分掛かることがある**（初回起動でモデルが未導入のとき）。
    /// 黙って待つと「押しても何も起きない」としか見えない。
    private mutating func applyInstallation(
        _ event: AssetInstallationEvent, at now: ContinuousClock.Instant
    ) {
        switch event {
        case .started:
            display = .message(HUDMessage(text: "音声認識モデルを導入しています…", severity: .info))
            // **期限を置かない。** いつ終わるか判らないものに数秒の期限を置くと、
            // 導入中なのに表示だけ消えて「押しても何も起きない」へ戻る。
            holdUntil = nil
            holdsIndefinitely = true
        case .progress(let fraction):
            let percent = Int((fraction * 100).rounded())
            display = .message(
                HUDMessage(text: "音声認識モデルを導入しています… \(percent) %", severity: .info))
            holdUntil = nil
            holdsIndefinitely = true
        case .completed:
            display = .message(HUDMessage(text: "音声認識モデルの導入が完了しました。", severity: .info))
            holdUntil = now + .seconds(3)
            holdsIndefinitely = false
        case .failed:
            display = .message(HUDMessage(text: "音声認識モデルを導入できませんでした。", severity: .warning))
            holdUntil = now + .seconds(5)
            holdsIndefinitely = false
        }
        pendingRecording = nil
    }

    // MARK: - 間引きと保持

    private mutating func stage(_ recording: HUDRecording, at now: ContinuousClock.Instant) {
        guard let last = lastRecordingCommit else {
            commit(recording, at: now)
            return
        }
        if now - last >= timing.minimumVolatileInterval {
            commit(recording, at: now)
        } else {
            // **最後の 1 件は捨てない。** `nextWakeup` が起こし直す時刻を返す。
            pendingRecording = recording
        }
    }

    private mutating func commit(_ recording: HUDRecording, at now: ContinuousClock.Instant) {
        display = .recording(recording)
        lastRecordingCommit = now
        pendingRecording = nil
    }

    private mutating func flushPendingIfDue(at now: ContinuousClock.Instant) {
        guard let pending = pendingRecording else { return }
        guard case .recording = display else {
            // 録音表示から抜けている。**古い中身は出さない。**
            pendingRecording = nil
            return
        }
        guard let last = lastRecordingCommit, now - last < timing.minimumVolatileInterval else {
            commit(pending, at: now)
            return
        }
    }

    private mutating func expireHoldIfDue(at now: ContinuousClock.Instant) {
        guard let until = holdUntil, now >= until else { return }
        holdUntil = nil
        display = .hidden
    }

    private func nextWakeup(after now: ContinuousClock.Instant) -> ContinuousClock.Instant? {
        var candidates: [ContinuousClock.Instant] = []
        if let until = holdUntil { candidates.append(until) }
        if pendingRecording != nil, let last = lastRecordingCommit {
            candidates.append(last + timing.minimumVolatileInterval)
        }
        return candidates.min()
    }
}
