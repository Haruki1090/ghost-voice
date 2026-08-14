import Foundation
import Testing

@testable import GhostVoiceCore

/// **変異解析（視点4）で生き残った振る舞いを固定する。**
///
/// 「生き残った」＝**その振る舞いを守っている検査が 1 つも無かった**という意味である。
/// ここに並ぶのは、コードを壊しても全件緑のままだった 5 件（E4 / E11 / A2 / E6 / A4 / A5）。
@Suite("(a) 分岐で守られていなかった振る舞い")
struct RevisionSurvivingMutationTests {

    /// **変異 E4 / E11。** (a) 分岐の secure input 拒否は、検査が 1 件も無かった
    /// （(b) 分岐の同じ門は検査があり、変異 E9 で赤くなる）。
    ///
    /// 門を外すと `.refusedSecureInput` は `recordableMethod == nil` の側で拾われて
    /// **`finishIdle()` へ落ちる。** 利用者から見えるのは
    /// 「HUD が何事も無かったように待機へ戻り、`.failed` も告知も出ないのに、
    /// テキストがどこにも無い」——フェーズ 1 の最終レビュー M-2 とまったく同じ形である。
    ///
    /// **配線を直した（本番で (a) が動くようになった）ことで、この経路は本番で初めて動く。**
    @Test("(a) 分岐: 挿入の直前に secure input が有効化されたら失敗として出す")
    func reportsSecureInputRefusalOnTheRawFirstPath() async throws {
        try await withTempRoot { root in
            // **経路判定を通した後・挿入する前**に有効化する
            // （整形前の判定（`completeUtterance`）は通り、(a) の分岐へ載ってから有効になる）。
            let rig = RevisionRig.make(root: root, secureInputAtInsertion: true)
            let log = StateLog()
            let collector = await log.collect(from: rig.session.stateUpdates)
            defer { collector.cancel() }
            let notices = rig.notices.follow(rig.session)
            defer { notices.cancel() }
            let run = Task { await rig.session.run() }
            defer { run.cancel() }

            rig.hotkey.emit(.pressed)
            try await waitUntil("録音が始まる") {
                if case .recording = await rig.session.state { return true }
                return false
            }
            rig.audio.emit(frames: 1_600)
            rig.hotkey.emit(.released)
            try await waitUntil("失敗が記録される") {
                await log.states.contains {
                    if case .failed = $0 { return true } else { return false }
                }
            }

            #expect(
                await log.states.contains(.failed(.refusedSecureInput)),
                "挿入されていないのに、失敗も告知も出ないまま待機へ落ちている")
            #expect(rig.history.entries.isEmpty, "パスワードかもしれない発話を履歴へ書いている")
            #expect(rig.content == RevisionRig.prefix + RevisionRig.suffix, "欄を触っている")
            #expect(rig.clipboard.left.isEmpty, "クリップボードにも残さないこと")
        }
    }

    /// **変異 A2。** 整形の打ち切りを (a)/(b) で取り違えても検査は緑だった——
    /// `SpyRefiner` が `timeout` を記録しておらず、
    /// **どちらの打ち切りが渡されたかを観測できる場所がテストに存在しなかった。**
    ///
    /// 取り違えると (a) の整形が 3000 ms ではなく 750 ms で打ち切られ、
    /// **約 40 字を超える発話では整形がほぼ必ず落ちる**（NFR-P6b が丸ごと効かなくなる）。
    @Test("(a) 分岐の整形には revisionDeadline が渡る")
    func theRawFirstPathUsesTheRevisionDeadline() async throws {
        try await withTempRoot { root in
            let refiner = SpyRefiner(result: RevisionRig.refined)
            let rig = RevisionRig.make(
                root: root, applyMode: .afterInsert, revisionDeadline: .seconds(3),
                refiner: refiner)
            try await rig.speakAndSettle()

            #expect(
                refiner.refineTimeouts == [.seconds(3)],
                "(a) 分岐なのに refinementTimeout（(b) 用）を渡している")
        }
    }

    /// 対照。**(b) 分岐には `refinementTimeout` が渡る。**
    /// 片側だけの検査は「常に同じ値を渡す実装」でも通ってしまう。
    @Test("(b) 分岐の整形には refinementTimeout が渡る")
    func theWaitingPathUsesTheRefinementTimeout() async throws {
        try await withTempRoot { root in
            let refiner = SpyRefiner(result: RevisionRig.refined)
            let rig = RevisionRig.make(
                root: root, applyMode: .beforeInsert, revisionDeadline: .seconds(3),
                refiner: refiner)
            try await rig.speakAndSettle(waitingForNotice: false)

            let settings = Settings()
            #expect(
                refiner.refineTimeouts == [settings.refinementTimeout],
                "(b) 分岐なのに revisionDeadline（(a) 用）を渡している")
            #expect(
                refiner.refineTimeouts != [.seconds(3)],
                "2 つの打ち切りが同じ値になっていて、取り違えを弁別できない")
        }
    }

    /// **変異 A4。** 錨が取れなかったときの告知を消しても検査は緑だった。
    /// 整形が反映されないのに、利用者へ何も告げない。
    @Test("錨が取れなかったら、反映しなかったことを告げる")
    func announcesWhenTheAnchorCouldNotBeCaptured() async throws {
        try await withTempRoot { root in
            // 書き込み後にキャレットが動かない相手＝錨を作れない
            // （`canCaptureAnchor()` は真を返すので (a) の分岐へは載る）。
            let rig = RevisionRig.make(root: root, caret: .startOfRange)
            try await rig.speakAndSettle()

            #expect(rig.content == RevisionRig.contentWithRaw, "生テキストは欄にある")
            #expect(
                rig.notices.notices == [.refinementNotApplied(nil)],
                "整形が反映されないのに利用者へ何も告げていない")
        }
    }

    /// **変異 E6。** (a) 分岐の挿入直後の `clearUndoTarget()` を消しても緑だった。
    ///
    /// 前の発話の錨が「戻せる」まま次の発話が挿入されるので、
    /// `hotkey.setUndoAvailable(true)` が降りない。**⌃⌘Z は下流アプリから奪われ続ける**のに、
    /// 押しても錨の世代が古く `.staleEpoch` で中止するため**何も起きない打鍵**になる。
    @Test("次の発話を挿入すると、前の発話の Undo の窓は閉じる")
    func insertingTheNextUtteranceClosesTheUndoWindow() async throws {
        try await withTempRoot { root in
            // **整形を遅らせる。** 2 発話目の差し替えがすぐ成功すると
            // `setUndoTarget` が窓を開け直すので、「閉じたか」を観測できない。
            let rig = RevisionRig.make(root: root, refineDelay: .milliseconds(400))
            let notices = rig.notices.follow(rig.session)
            defer { notices.cancel() }
            let run = Task { await rig.session.run() }
            defer { run.cancel() }

            try await rig.speakOnce(on: run)
            try await waitUntil("差し替えが終わる") { !rig.notices.notices.isEmpty }
            #expect(await rig.session.canUndo, "差し替えの後に窓が開いていない（検査が空回り）")
            #expect(rig.hotkey.isUndoAvailable, "打鍵の横取りが始まっていない（検査が空回り）")

            rig.apply(.restored)
            // 2 発話目の**挿入が終わった時点**で見る（差し替えはまだ保留中）。
            try await rig.speakOnce(on: run)

            // **`canUndo` はここでは使えない**——保留中の差し替えがあると
            // 「取りやめられる」という別の意味で真を返す（`DictationSession.canUndo`）。
            // 見るべきは**打鍵を奪う旗**のほうである。
            #expect(
                !rig.hotkey.isUndoAvailable,
                "前の発話の錨が戻せるまま残っており、⌃⌘Z を下流アプリから奪い続けている（押しても世代が古く .staleEpoch で中止するので、何も起きない打鍵になる）")
        }
    }

    /// **変異 A5。** Undo の窓を 10 秒 → 1 秒にしても緑だった。
    ///
    /// 告知の文言は `HistoryStore.undoWindow` から「10 秒以内」と出るのに、
    /// **実際の窓は 1 秒**になる。**利用者に嘘を言う。**
    ///
    /// - Note: 1.2 秒待つのは**変異（1 秒）を殺すための線**であって、要件値ではない。
    ///   要件は `HistoryStore.undoWindow`（10 秒）である。
    @Test("差し替えから 1.2 秒たっても Undo の窓は開いたまま")
    func theUndoWindowOutlivesAShortWait() async throws {
        try await withTempRoot { root in
            let rig = RevisionRig.make(root: root)
            let notices = rig.notices.follow(rig.session)
            defer { notices.cancel() }
            let run = Task { await rig.session.run() }
            defer { run.cancel() }

            try await rig.speakOnce(on: run)
            try await waitUntil("差し替えが終わる") { !rig.notices.notices.isEmpty }
            #expect(await rig.session.canUndo)

            #expect(HistoryStore.undoWindow >= 10, "窓の要件値が変わっている")
            try await Task.sleep(for: .milliseconds(1_200))

            #expect(
                await rig.session.canUndo,
                "窓が要件（\(HistoryStore.undoWindow) 秒）より早く閉じている")
        }
    }
}
