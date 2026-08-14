import Foundation
import GhostVoiceCore
import Testing

@testable import GhostVoiceApp

/// **状態の並びを表示へ翻訳する規則**（詳細設計書 §7.4 / 基本設計書 §8.2）。
///
/// 時計を注入するのではなく `ContinuousClock.Instant` を**引数で渡す**形にしてある。
/// おかげでここの検査は 1 度も待たない——**実時間を待つ検査は、機体が忙しいと嘘をつく。**
@Suite("HUD の表示規則（保持・間引き・通知）")
struct HUDPresenterTests {

    private func makePresenter() -> HUDPresenter {
        HUDPresenter(languageBadge: "日")
    }

    // MARK: - `.failed` の直後の `.idle`

    /// **この検査がこの型の存在理由である。**
    ///
    /// `DictationSession.fail()` は `.failed` と `.idle` を**同期で続けて emit する。**
    /// 状態をそのまま描く実装では、エラーは 1 フレームも見えない。
    @Test("`.failed` の直後に `.idle` が来てもエラーが消えない")
    func failureSurvivesTheImmediateIdle() {
        var presenter = makePresenter()
        let start = ContinuousClock.now

        presenter.apply(.state(.failed(.noSpeechRecognized)), at: start)
        guard case .message(let message) = presenter.display else {
            Issue.record("エラーが出ていない: \(presenter.display)")
            return
        }
        #expect(message.text == "認識できませんでした。")

        // **同じ瞬間に `.idle` が来る。**
        presenter.apply(.state(.idle), at: start)
        #expect(presenter.display == .message(message))

        // 3 秒経つまでは残る。
        presenter.apply(.tick, at: start + .milliseconds(2900))
        #expect(presenter.display == .message(message))

        presenter.apply(.tick, at: start + .seconds(3))
        #expect(presenter.display == .hidden)
    }

    @Test("`.failed` は起こし直す時刻を返す（返さないとエラーが消えない）")
    func failureSchedulesItsOwnExpiry() throws {
        var presenter = makePresenter()
        let start = ContinuousClock.now
        let wake = presenter.apply(.state(.failed(.audioUnavailable)), at: start)
        #expect(try #require(wake) == start + .seconds(3))
    }

    /// **発話を失った回だけ長く出す。** 毎回強く出すと本当に失った回が埋もれる
    /// （`SessionFailureNotice.speechWasLost` の注記）。
    @Test("発話を失った失敗は 8 秒残る")
    func lostSpeechIsHeldLonger() {
        var presenter = makePresenter()
        let start = ContinuousClock.now
        presenter.apply(.state(.failed(.historyUnavailable(insertedElsewhere: false))), at: start)
        guard case .message(let message) = presenter.display else {
            Issue.record("表示が message でない: \(presenter.display)")
            return
        }
        #expect(message.severity == .lost)

        presenter.apply(.tick, at: start + .seconds(7))
        #expect(presenter.display != .hidden)
        presenter.apply(.tick, at: start + .seconds(8))
        #expect(presenter.display == .hidden)
    }

    /// **secure input は「エラー」ではない**（基本設計書 §7 の唯一の例外）。
    /// 赤く出すと「失敗した、もう一度」と読まれ、パスワード欄へ挿入させようとする案内になる。
    @Test("secure input の拒否は失敗と違う重さで出す")
    func secureInputIsNotAnError() {
        var presenter = makePresenter()
        presenter.apply(.state(.failed(.refusedSecureInput)), at: .now)
        guard case .message(let message) = presenter.display else {
            Issue.record("表示が message でない")
            return
        }
        #expect(message.severity == .refusal)
        #expect(message.text == "パスワード入力欄（secure input）が有効でした。")
    }

    /// **エラーを出している最中に次の発話が始まったら、そちらが勝つ。**
    /// 話しているのに前のエラーを出し続けるのは嘘である。
    @Test("保持中でも新しい発話が始まれば録音表示へ切り替わる")
    func newUtteranceBeatsAHeldMessage() {
        var presenter = makePresenter()
        let start = ContinuousClock.now
        presenter.apply(.state(.failed(.noSpeechRecognized)), at: start)
        presenter.apply(.state(.idle), at: start)
        presenter.apply(.state(.recording(volatileText: "")), at: start + .milliseconds(500))
        #expect(
            presenter.display
                == .recording(HUDRecording(level: 0, languageBadge: "日", volatileText: "")))
    }

    // MARK: - チェックマーク

    @Test("挿入が終わるとチェックマークを 0.6 秒出して畳む")
    func completionCheckmark() {
        var presenter = makePresenter()
        let start = ContinuousClock.now
        presenter.apply(.state(.inserting), at: start)
        #expect(presenter.display == .processing(.inserting))
        presenter.apply(.state(.idle), at: start)
        #expect(presenter.display == .completed)
        presenter.apply(.tick, at: start + .milliseconds(599))
        #expect(presenter.display == .completed)
        presenter.apply(.tick, at: start + .milliseconds(600))
        #expect(presenter.display == .hidden)
    }

    /// 中断（ESC）や「認識できなかった」で `.idle` へ戻る経路。
    /// **挿入していないのにチェックマークを出したら嘘になる。**
    @Test("挿入していない `.idle` ではチェックマークを出さない")
    func noCheckmarkWithoutInsertion() {
        var presenter = makePresenter()
        let start = ContinuousClock.now
        presenter.apply(.state(.recording(volatileText: "あ")), at: start)
        presenter.apply(.state(.idle), at: start + .milliseconds(10))
        #expect(presenter.display == .hidden)

        presenter.apply(.state(.finalizing), at: start + .seconds(1))
        presenter.apply(.state(.idle), at: start + .seconds(1))
        #expect(presenter.display == .hidden)
    }

    /// A4 が配線した (a) の並び: `.inserting` → `.idle` → **`.revising`** → `.idle`。
    /// **2 度目の `.idle` でチェックマークをもう一度出さない**（同じ発話で 2 回出る）。
    @Test("差し替えの後の `.idle` ではチェックマークを繰り返さない")
    func revisionDoesNotRepeatTheCheckmark() {
        var presenter = makePresenter()
        let start = ContinuousClock.now
        presenter.apply(.state(.inserting), at: start)
        presenter.apply(.state(.idle), at: start)
        #expect(presenter.display == .completed)
        presenter.apply(.state(.revising), at: start + .milliseconds(100))
        #expect(presenter.display == .processing(.revising))
        presenter.apply(.state(.idle), at: start + .milliseconds(900))
        #expect(presenter.display == .hidden)
    }

    /// 基本設計書 §8.2: 差し替えは**控えめに出す。**
    /// 挿入は既に終わっており、断念しても生テキストは欄に残る。
    @Test("差し替え中は控えめな表示になる")
    func revisionIsSubdued() {
        #expect(HUDProcessing.revising.isSubdued)
        #expect(!HUDProcessing.finalizing.isSubdued)
        #expect(!HUDProcessing.refining.isSubdued)
        #expect(!HUDProcessing.inserting.isSubdued)
    }

    // MARK: - 暫定テキストの間引き

    /// **メインスレッドを塞ぐと `CGEventTap` の配送が p50 0.045 ms → 12.8 ms へ悪化する**
    /// （ランループ検証の実測）。暫定テキストは `.volatile` 更新のたびに届くので、
    /// 素通しすると描画が更新の回数だけ走る。
    @Test("録音中の連続した更新は間引かれる")
    func volatileUpdatesAreThrottled() {
        var presenter = makePresenter()
        let start = ContinuousClock.now

        // 変わり目は即座に反映する。
        presenter.apply(.state(.recording(volatileText: "こ")), at: start)
        #expect(presenter.display.recordingText == "こ")

        // 50 ms 未満の更新は保留される。
        presenter.apply(.state(.recording(volatileText: "こん")), at: start + .milliseconds(10))
        #expect(presenter.display.recordingText == "こ")
        presenter.apply(.state(.recording(volatileText: "こんに")), at: start + .milliseconds(20))
        #expect(presenter.display.recordingText == "こ")

        // 50 ms を過ぎたら**最新のものが**出る（途中のものは出ない）。
        presenter.apply(.state(.recording(volatileText: "こんにち")), at: start + .milliseconds(50))
        #expect(presenter.display.recordingText == "こんにち")
    }

    /// **末尾を保留したまま捨てない。** 話し終えた直後の最後の暫定テキストが
    /// 出ないと、「言ったのに出ていない」形になる。
    @Test("保留した最後の 1 件は起こし直しで必ず出る")
    func theLastPendingUpdateIsNeverDropped() throws {
        var presenter = makePresenter()
        let start = ContinuousClock.now
        presenter.apply(.state(.recording(volatileText: "こ")), at: start)
        let pending = presenter.apply(
            .state(.recording(volatileText: "こんばんは")), at: start + .milliseconds(5))
        let wake = try #require(pending)
        #expect(wake == start + .milliseconds(50))
        #expect(presenter.display.recordingText == "こ")

        presenter.apply(.tick, at: wake)
        #expect(presenter.display.recordingText == "こんばんは")
    }

    /// **変わり目は間引かない。** ここを間引くと「録音が終わっているのに録音表示のまま」になる。
    @Test("録音から抜ける状態の変化は間引かれない")
    func stateTransitionsAreNeverThrottled() {
        var presenter = makePresenter()
        let start = ContinuousClock.now
        presenter.apply(.state(.recording(volatileText: "あ")), at: start)
        presenter.apply(.state(.finalizing), at: start + .milliseconds(1))
        #expect(presenter.display == .processing(.finalizing))
    }

    /// 保留した中身は、録音表示から抜けたら**捨てる。**
    /// 残すと、処理中の表示のあとに古い暫定テキストが割り込む。
    @Test("録音表示から抜けたら保留していた中身は捨てる")
    func pendingUpdatesAreDiscardedWhenRecordingEnds() {
        var presenter = makePresenter()
        let start = ContinuousClock.now
        presenter.apply(.state(.recording(volatileText: "あ")), at: start)
        presenter.apply(.state(.recording(volatileText: "あい")), at: start + .milliseconds(5))
        presenter.apply(.state(.finalizing), at: start + .milliseconds(6))
        presenter.apply(.tick, at: start + .seconds(1))
        #expect(presenter.display == .processing(.finalizing))
    }

    // MARK: - 音量

    @Test("音量は録音表示のときだけ映り、`.idle` で 0 に戻る")
    func levelOnlyShowsWhileRecording() {
        var presenter = makePresenter()
        let start = ContinuousClock.now
        presenter.apply(.level(0.15), at: start)
        #expect(presenter.display == .hidden)

        presenter.apply(.state(.recording(volatileText: "")), at: start)
        #expect(presenter.display.recordingLevel == 0.15)

        presenter.apply(.level(0.3), at: start + .milliseconds(100))
        #expect(presenter.display.recordingLevel == 0.3)

        // **「無音の 0」は流れてこない**（`levelStream()` の注記）ので、状態の側で落とす。
        presenter.apply(.state(.idle), at: start + .milliseconds(200))
        presenter.apply(.state(.recording(volatileText: "")), at: start + .milliseconds(300))
        #expect(presenter.display.recordingLevel == 0)
    }

    // MARK: - 言語バッジ

    @Test("言語バッジをロケール識別子から作る")
    func languageBadges() {
        #expect(HUDLanguageBadge.text(forLocaleIdentifier: "ja-JP") == "日")
        #expect(HUDLanguageBadge.text(forLocaleIdentifier: "en-US") == "EN")
        #expect(HUDLanguageBadge.text(forLocaleIdentifier: "fr-FR") == "FR")
        #expect(HUDLanguageBadge.text(forLocaleIdentifier: "") == "?")
    }

    @Test("録音の表示に言語バッジが載る")
    func recordingCarriesTheBadge() {
        var presenter = HUDPresenter(languageBadge: "EN")
        presenter.apply(.state(.recording(volatileText: "hello")), at: .now)
        #expect(presenter.display.recordingBadge == "EN")
    }

    // MARK: - 通知

    /// **`.refinementNotApplied(nil)` を出さない理由は、頻度である。**
    /// nil は「整形そのものが返らなかった」で、実測では 56 字の発話が締め切りの内側で
    /// 整形を終えていても 10/10 で捨てられている（V-37）。毎回出すと、本当に重い
    /// `.textMayHaveBeenLost` が埋もれる。**理由がある側（差し替えの断念）は出す。**
    @Test("整形が返らなかっただけの通知は出さない")
    func quietAboutRefinementThatNeverReturned() {
        #expect(HUDPresenter.announcement(for: .refinementNotApplied(nil)) == nil)
        #expect(HUDPresenter.announcement(for: .refinementApplied) == nil)
        #expect(HUDPresenter.announcement(for: .refinementNotApplied(.focusChanged)) != nil)
    }

    /// R-9。**この設計で唯一「発話が欄から消えうる」経路**なので、回収を促す必要がある。
    @Test("喪失の疑いは最も強い重さで、話している最中でも割り込む")
    func lostTextAlwaysInterrupts() {
        var presenter = makePresenter()
        let start = ContinuousClock.now
        presenter.apply(.state(.recording(volatileText: "つづき")), at: start)
        presenter.apply(.notice(.textMayHaveBeenLost), at: start + .milliseconds(60))
        guard case .message(let message) = presenter.display else {
            Issue.record("割り込めていない: \(presenter.display)")
            return
        }
        #expect(message.severity == .lost)
    }

    /// 話し始めているのに Undo の顛末を割り込ませない（喪失の疑いだけが例外）。
    @Test("録音中に軽い通知は割り込まない")
    func lightNoticesDoNotInterruptRecording() {
        var presenter = makePresenter()
        let start = ContinuousClock.now
        presenter.apply(.state(.recording(volatileText: "つづき")), at: start)
        presenter.apply(.notice(.undone), at: start + .milliseconds(60))
        #expect(presenter.display.recordingText == "つづき")
    }

    @Test("喪失の疑いを出している間は軽い通知で上書きしない")
    func lostMessageIsNotOverwritten() {
        var presenter = makePresenter()
        let start = ContinuousClock.now
        presenter.apply(.notice(.textMayHaveBeenLost), at: start)
        presenter.apply(.notice(.undoUnavailable), at: start + .milliseconds(100))
        guard case .message(let message) = presenter.display else {
            Issue.record("表示が message でない")
            return
        }
        #expect(message.severity == .lost)
    }

    @Test("Undo の顛末は短く出して畳む")
    func undoNoticesAreShort() {
        var presenter = makePresenter()
        let start = ContinuousClock.now
        presenter.apply(.notice(.undone), at: start)
        #expect(presenter.display == .message(HUDMessage(text: "整形前へ戻しました。", severity: .info)))
        presenter.apply(.tick, at: start + .milliseconds(1500))
        #expect(presenter.display == .hidden)
    }

    /// **すべての通知に扱いが決まっている**ことを固定する。
    /// 新しい通知が Core に増えたとき、ここが網羅を強制する。
    @Test("すべての通知の扱いが決まっている")
    func everyNoticeIsHandled() {
        let all: [SessionNotice] = [
            .refinementApplied, .refinementNotApplied(nil), .refinementNotApplied(.sourceMismatch),
            .textMayHaveBeenLost, .undone, .undoUnavailable, .undoDeclined(.focusChanged),
            .undoCopiedRawTextToClipboard,
        ]
        // 黙って捨てるのは「整形の結末」の 2 つだけ。
        let silent = all.filter { HUDPresenter.announcement(for: $0) == nil }
        #expect(silent == [.refinementApplied, .refinementNotApplied(nil)])
    }

    // MARK: - モデルの導入

    /// フェーズ 1 では「導入が始まった」の 1 回きりしか出せず、**数分掛かる導入のあいだ
    /// 利用者には「押しても何も起きない」としか見えなかった。**
    @Test("モデルの導入中は期限を置かずに出し続ける")
    func installationHasNoDeadline() {
        var presenter = makePresenter()
        let start = ContinuousClock.now
        let wake = presenter.apply(.installation(.started), at: start)
        // **期限を置かない。** いつ終わるか判らないものを数秒で消すと元の木阿弥になる。
        #expect(wake == nil)
        presenter.apply(.tick, at: start + .seconds(600))
        #expect(presenter.display != .hidden)

        presenter.apply(.installation(.progress(0.42)), at: start + .seconds(601))
        #expect(
            presenter.display
                == .message(HUDMessage(text: "音声認識モデルを導入しています… 42 %", severity: .info)))

        presenter.apply(.installation(.completed), at: start + .seconds(700))
        presenter.apply(.tick, at: start + .seconds(703))
        #expect(presenter.display == .hidden)
    }

    // MARK: - 発話に由来しない告知

    @Test("起動時の告知は次の発話で消える")
    func announcementsYieldToTheNextUtterance() {
        var presenter = makePresenter()
        let start = ContinuousClock.now
        presenter.announce(
            HUDMessage(text: "キー入力を監視できません。", severity: .warning), hold: .seconds(10), at: start)
        #expect(presenter.display != .hidden)
        presenter.apply(.state(.recording(volatileText: "")), at: start + .seconds(1))
        #expect(presenter.display.recordingText == "")
    }
}

extension HUDDisplay {
    fileprivate var recordingText: String? {
        if case .recording(let recording) = self { return recording.volatileText }
        return nil
    }
    fileprivate var recordingLevel: Float? {
        if case .recording(let recording) = self { return recording.level }
        return nil
    }
    fileprivate var recordingBadge: String? {
        if case .recording(let recording) = self { return recording.languageBadge }
        return nil
    }
}
