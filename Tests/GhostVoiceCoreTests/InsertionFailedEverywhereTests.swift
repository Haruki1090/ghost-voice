import Foundation
import Testing

@testable import GhostVoiceCore

/// **「どこにも挿入できず、クリップボードへも残せなかった」世界**（`.failedEverywhere`）。
///
/// 再レビューで判ったのは、この世界がセッション層のテストに 1 つも無かったことである
/// （`grep -rn "failedEverywhere" Tests/` が 0 件だった）。そのせいで
///
/// - **(a) 分岐**: 履歴上限 0 と重なると `finishIdle()` へ落ち、**発話が欄にも
///   クリップボードにも履歴にも無いまま、失敗を 1 つも出さずに成功として終わる**（A-1）
/// - **(b) 分岐**: 同じ組み合わせで `.insertionFailed` は出るが、文言が
///   「履歴にだけ残っています」・`speechWasLost = false` で、**事実と逆**（B-1）
///
/// の 2 つが揃って生き残った。**片方の分岐だけ直しても意味が無い**ので、
/// 4 通り（(a)/(b) × 履歴が残る/残らない）を 1 つの表としてここで押さえる。
///
/// | 分岐 | 履歴上限 | 欄 | クリップボード | 履歴 | 出るべきもの |
/// |---|---|---|---|---|---|
/// | (a) | 50 | — | — | 1 件 | `.insertionFailed(retainedInHistory: true)` |
/// | (a) | 0 | — | — | 0 件 | `.insertionFailed(retainedInHistory: false)`（発話は失われた） |
/// | (b) | 50 | — | — | 1 件 | `.insertionFailed(retainedInHistory: true)` |
/// | (b) | 0 | — | — | 0 件 | `.insertionFailed(retainedInHistory: false)`（発話は失われた） |
@Suite("どこにも挿入できずクリップボードへも残せない世界")
struct InsertionFailedEverywhereTests {

    /// 一段目（AX）が書き込みを拒み、二段目は適用外、最後の砦（クリップボード）も
    /// 置けない世界を作る。**`CompositeInserter` は `.failedEverywhere` を返す。**
    private func makeRig(root: URL, historyLimit: Int, applyMode: RefinementApplyMode)
        -> RevisionRig
    {
        RevisionRig.make(
            root: root,
            applyMode: applyMode,
            acceptsWrite: false,
            historyLimit: historyLimit,
            clipboardSucceeds: false
        )
    }

    /// 1 発話流し、**縮退が出るまで**待つ。**`.idle` を待ってはならない**——
    /// A-1 はまさに「失敗を出さずに `.idle` で終わる」欠陥なので、
    /// `.idle` を目印にすると欠陥のある実装でも緑になる。
    private func speakAndAwaitFailure(_ rig: RevisionRig, _ log: StateLog) async throws {
        rig.hotkey.emit(.pressed)
        try await waitUntil("録音が始まる") {
            if case .recording = await rig.session.state { return true }
            return false
        }
        rig.audio.emit(frames: 1_600)
        rig.hotkey.emit(.released)
        try await waitUntil("縮退が記録される") {
            await log.states.contains { if case .failed = $0 { true } else { false } }
        }
    }

    /// 記録された最初の縮退。
    private func firstFailure(_ states: [SessionState]) -> SessionFailure? {
        states.compactMap { if case .failed(let failure) = $0 { failure } else { nil } }.first
    }

    // MARK: - (a) 生テキストを先に挿入する分岐

    /// **これが A-1 そのものである。**
    ///
    /// `record` の顛末を見る `guard` が `.failedEverywhere` の判定より**前**にあるため、
    /// 上限 0 では先に `finishIdle()` で抜けていた。しかも `.refinementNotApplied(nil)` は
    /// `SessionNoticeAnnouncement.init?` が nil を返すので、**HUD にも CLI にも何も出ない。**
    @Test("(a) 上限 0 でどこにも挿入できなければ、失われたことを知らせる")
    func announcesLossInTheAnchoringBranchWhenNothingIsRetained() async throws {
        try await withTempRoot { root in
            let rig = makeRig(root: root, historyLimit: 0, applyMode: .afterInsert)
            let log = StateLog()
            let collector = await log.collect(from: rig.session.stateUpdates)
            defer { collector.cancel() }
            let notices = rig.notices.follow(rig.session)
            defer { notices.cancel() }
            let run = Task { await rig.session.run() }
            defer { run.cancel() }

            try await speakAndAwaitFailure(rig, log)

            // そのとき発話はどこにあるか——**どこにも無い。**
            #expect(rig.content == RevisionRig.prefix + RevisionRig.suffix, "欄には入っていない")
            #expect(rig.clipboard.left.isEmpty, "クリップボードにも置けていない")
            #expect(rig.history.entries.isEmpty, "履歴にも残っていない")

            let failure = firstFailure(await log.states)
            #expect(failure != nil, "発話がどこにも無いのに失敗が 1 つも出ていない")
            if let failure {
                let notice = SessionFailureNotice(failure)
                #expect(notice.speechWasLost, "発話は失われているのに『失われていない』と告げている")
                #expect(
                    !(notice.summary + notice.detail).contains("履歴にだけ残っています"),
                    "履歴は 0 件なのに履歴画面へ案内している")
            }
        }
    }

    /// 履歴が生きていれば**発話は失われていない。** 同じ縮退でも意味が違う。
    @Test("(a) 履歴に残せていれば、履歴画面へ案内する")
    func pointsAtTheHistoryInTheAnchoringBranchWhenTheCopySurvives() async throws {
        try await withTempRoot { root in
            let rig = makeRig(root: root, historyLimit: 50, applyMode: .afterInsert)
            let log = StateLog()
            let collector = await log.collect(from: rig.session.stateUpdates)
            defer { collector.cancel() }
            let run = Task { await rig.session.run() }
            defer { run.cancel() }

            try await speakAndAwaitFailure(rig, log)

            #expect(rig.content == RevisionRig.prefix + RevisionRig.suffix, "欄には入っていない")
            #expect(rig.clipboard.left.isEmpty, "クリップボードにも置けていない")
            #expect(rig.history.entries.count == 1, "履歴が最後の写しなのに残っていない")
            #expect(rig.history.entries.first?.insertionMethod == .notInserted)

            let failure = firstFailure(await log.states)
            #expect(failure != nil)
            if let failure {
                let notice = SessionFailureNotice(failure)
                #expect(!notice.speechWasLost, "履歴に残っているのに『失われた』と告げている")
                #expect(notice.detail.contains("履歴"), "唯一の写しの在り処を案内していない")
            }
        }
    }

    // MARK: - (b) 整形を待ってから挿入する分岐

    /// **これが B-1 そのものである。**
    ///
    /// (b) は `.insertionFailed` を出すので A-1 のような無言の成功にはならない。
    /// しかし文言が「この発話は履歴にだけ残っています」で、**履歴は 0 件**だった。
    @Test("(b) 上限 0 でどこにも挿入できなければ、失われたことを知らせる")
    func announcesLossInTheWaitingBranchWhenNothingIsRetained() async throws {
        try await withTempRoot { root in
            let rig = makeRig(root: root, historyLimit: 0, applyMode: .beforeInsert)
            let log = StateLog()
            let collector = await log.collect(from: rig.session.stateUpdates)
            defer { collector.cancel() }
            let run = Task { await rig.session.run() }
            defer { run.cancel() }

            try await speakAndAwaitFailure(rig, log)

            #expect(rig.content == RevisionRig.prefix + RevisionRig.suffix, "欄には入っていない")
            #expect(rig.clipboard.left.isEmpty, "クリップボードにも置けていない")
            #expect(rig.history.entries.isEmpty, "履歴にも残っていない")

            let failure = firstFailure(await log.states)
            #expect(failure != nil, "発話がどこにも無いのに失敗が 1 つも出ていない")
            if let failure {
                let notice = SessionFailureNotice(failure)
                #expect(notice.speechWasLost, "発話は失われているのに『失われていない』と告げている")
                #expect(
                    !(notice.summary + notice.detail).contains("履歴にだけ残っています"),
                    "履歴は 0 件なのに履歴画面へ案内している")
            }
        }
    }

    @Test("(b) 履歴に残せていれば、履歴画面へ案内する")
    func pointsAtTheHistoryInTheWaitingBranchWhenTheCopySurvives() async throws {
        try await withTempRoot { root in
            let rig = makeRig(root: root, historyLimit: 50, applyMode: .beforeInsert)
            let log = StateLog()
            let collector = await log.collect(from: rig.session.stateUpdates)
            defer { collector.cancel() }
            let run = Task { await rig.session.run() }
            defer { run.cancel() }

            try await speakAndAwaitFailure(rig, log)

            #expect(rig.content == RevisionRig.prefix + RevisionRig.suffix, "欄には入っていない")
            #expect(rig.clipboard.left.isEmpty, "クリップボードにも置けていない")
            #expect(rig.history.entries.count == 1, "履歴が最後の写しなのに残っていない")
            #expect(rig.history.entries.first?.insertionMethod == .notInserted)

            let failure = firstFailure(await log.states)
            #expect(failure != nil)
            if let failure {
                let notice = SessionFailureNotice(failure)
                #expect(!notice.speechWasLost, "履歴に残っているのに『失われた』と告げている")
                #expect(notice.detail.contains("履歴"), "唯一の写しの在り処を案内していない")
            }
        }
    }
}
