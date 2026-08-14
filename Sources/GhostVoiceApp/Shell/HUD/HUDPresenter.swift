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
        return nextWakeup(after: now)
    }

    // MARK: - 状態

    private mutating func applyState(_ state: SessionState, at now: ContinuousClock.Instant) {
        switch state {
        case .recording(let volatileText):
            // **新しい発話は、保持中のどんな表示にも勝つ。**
            // 利用者が話し始めているのに前のエラーを出し続けるのは嘘である。
            holdUntil = nil
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

        case .idle:
            pendingRecording = nil
            // **音量は録音が終わっても「無音の 0」が流れてこない**（`levelStream()` の注記）。
            // ここで落とさないとインジケータが振れたまま止まる。
            level = 0
            // 保持中（エラーの直後の `.idle` がこれ）なら何も変えない。
            guard holdUntil == nil else { return }
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
        guard let announcement = HUDPresenter.announcement(for: notice) else { return }

        // **喪失の疑いだけは何を差し置いても出す**（R-9。回収を促す必要がある）。
        if announcement.severity != .lost {
            // 話している最中に割り込まない。
            if case .recording = display { return }
            // 既に「失われたかもしれない」を出しているなら上書きしない。
            if case .message(let current) = display, current.severity == .lost, holdUntil != nil {
                return
            }
        }

        pendingRecording = nil
        display = .message(HUDMessage(text: announcement.text, severity: announcement.severity))
        holdUntil = now + announcement.hold
    }

    struct Announcement: Equatable {
        let text: String
        let severity: HUDSeverity
        let hold: Duration
    }

    /// **どの通知を出し、どれを黙って捨てるか。**
    ///
    /// - `.refinementApplied` は**出さない。** 欄の文字が整ったこと自体が結果であり、
    ///   毎回「反映しました」と言うのは通知のためだけの通知になる。
    /// - **`.refinementNotApplied(nil)` も出さない。** nil は「整形そのものが返らなかった」
    ///   （打ち切り・利用不可・逸脱の検査に落ちた）であり、**これは珍しくない**——
    ///   実測で 56 字の発話は整形が締め切りの内側で完了していても 10/10 で捨てられている
    ///   （V-37）。毎回出すと、本当に重い `.textMayHaveBeenLost` が埋もれる。
    /// - **`.refinementNotApplied(理由あり)` は出す。** こちらは「差し替えを断念した」で、
    ///   詳細設計書 §7.4 が明示的に告げよと言っている側である。
    static func announcement(for notice: SessionNotice) -> Announcement? {
        switch notice {
        case .refinementApplied:
            return nil
        case .refinementNotApplied(let reason):
            guard reason != nil else { return nil }
            return Announcement(
                text: "整形を反映できませんでした（入力済みの文はそのままです）。",
                severity: .warning, hold: .seconds(2))
        case .textMayHaveBeenLost:
            return Announcement(
                text: "入力欄のテキストが失われた可能性があります。クリップボードから貼り直せます。",
                severity: .lost, hold: .seconds(8))
        case .undone:
            return Announcement(text: "整形前へ戻しました。", severity: .info, hold: .milliseconds(1500))
        case .undoUnavailable:
            return Announcement(text: "戻せるものがありません。", severity: .info, hold: .milliseconds(1500))
        case .undoDeclined:
            return Announcement(
                text: "戻せませんでした（入力欄の内容が変わっています）。", severity: .warning, hold: .seconds(2))
        case .undoCopiedRawTextToClipboard:
            return Announcement(
                text: "整形前のテキストをクリップボードへ入れました。", severity: .info, hold: .milliseconds(2500))
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
        case .progress(let fraction):
            let percent = Int((fraction * 100).rounded())
            display = .message(
                HUDMessage(text: "音声認識モデルを導入しています… \(percent) %", severity: .info))
            holdUntil = nil
        case .completed:
            display = .message(HUDMessage(text: "音声認識モデルの導入が完了しました。", severity: .info))
            holdUntil = now + .seconds(3)
        case .failed:
            display = .message(HUDMessage(text: "音声認識モデルを導入できませんでした。", severity: .warning))
            holdUntil = now + .seconds(5)
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
