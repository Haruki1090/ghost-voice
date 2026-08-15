import Foundation
import Synchronization
import Testing

@testable import GhostVoiceCore

// MARK: - 検査用の道具

/// **整形が返る順番を検査から握る代役。**
///
/// 保留中の差し替えが 2 件重なる状況は、`SpyRefiner` の「一定時間遅れて返る」では
/// 決定的に作れない——1 件目が返る前に 2 件目の挿入が終わることを、
/// **時間ではなく順序で**保証する必要がある。
///
/// `refine` は呼ばれた順に 0 番から番号を振り、`release(_:)` が来るまで返らない。
/// 検査は「N 件目の整形が始まった」を `startedCount` で待ってから次の発話を流せる。
final class GatedRefiner: Refining, @unchecked Sendable {

    private struct State {
        var started = 0
        var released: Set<Int> = []
        var waiting: [Int: CheckedContinuation<Void, Never>] = [:]
    }

    private let state = Mutex(State())
    private let result: String?

    init(result: String?) {
        self.result = result
    }

    /// これまでに `refine` が呼ばれた回数。**検査はここを目印に次の発話を流す。**
    var startedCount: Int { state.withLock { $0.started } }

    var isAvailable: Bool { result != nil }

    func prewarm() async {}

    /// `index` 番目（0 起点）の整形を返す。**返す前に呼んでもよい。**
    func release(_ index: Int) {
        let waiting = state.withLock { current -> CheckedContinuation<Void, Never>? in
            current.released.insert(index)
            return current.waiting.removeValue(forKey: index)
        }
        waiting?.resume()
    }

    func refine(
        _ raw: String, locale: Locale, terms: [VocabularyTerm], timeout: Duration
    ) async -> String? {
        let index = state.withLock { current -> Int in
            defer { current.started += 1 }
            return current.started
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let alreadyReleased = state.withLock { current -> Bool in
                if current.released.contains(index) { return true }
                current.waiting[index] = continuation
                return false
            }
            if alreadyReleased { continuation.resume() }
        }
        return result
    }
}

// MARK: - 検査

/// **保留中の差し替えが 2 件重なったときに、新しい方の持ち手が消えないこと。**
///
/// (a) の分岐は挿入の直後に `.idle` へ戻して次の PTT を受け付ける（設計 opus §3.3）ので、
/// **2 件が重なるのは例外ではなく通常経路である。**
/// 重なった状態で古い方の差し替えが片付くと、`pendingRevision` を発話番号で
/// 照合せずに nil へ落としていたため、**新しい方の持ち手が消えていた**
/// （最終レビュー 視点3 の指摘 3）。
///
/// 持ち手が消えても**発話は失われない**——生テキストは欄にも履歴にもあり、
/// 差し替えは正しい欄へ正しい内容を書く。壊れるのは**取りやめの側**である。
///
/// | 何が壊れるか | 利用者から見えること |
/// |---|---|
/// | ESC が効かない | 取りやめたのに欄が整形結果へ書き換わる |
/// | `canUndo` が偽 | 「戻す」ボタンが押せない |
/// | Undo キーが縮退へ落ちる | 取りやめではなくクリップボードの奪取を試みる |
@Suite("保留中の差し替えが 2 件重なったとき")
struct OverlappingRevisionTests {

    /// 2 発話ぶんの生テキストが並んだ欄の中身。**差し替えを 1 件も撃っていない形。**
    ///
    /// 挿入は前の挿入の直後（`FakeTextField.CaretAfterWrite.endOfWrittenText`）へ続く。
    static var contentWithTwoRaws: String {
        RevisionRig.prefix + RevisionRig.raw + RevisionRig.raw + RevisionRig.suffix
    }

    /// 2 件目だけ差し替わった欄の中身。**1 件目は世代が失効しているので生のまま。**
    static var contentWithRawThenRefined: String {
        RevisionRig.prefix + RevisionRig.raw + RevisionRig.refined + RevisionRig.suffix
    }

    /// 保留を 2 件重ねて、**古い方だけ**を片付けたところまで進める。
    ///
    /// 抜けた時点で、2 件目の整形（`release(1)`）はまだ返していない。
    private func overlapTwoRevisions(
        _ rig: RevisionRig, _ refiner: GatedRefiner, on run: Task<Void, Never>
    ) async throws {
        // 発話 1。整形は返らないので保留のまま `.idle` へ戻る。
        try await rig.speakOnce(on: run)
        try await waitUntil("1 件目の整形が始まる") { refiner.startedCount >= 1 }

        // 発話 2。**ここで保留が 2 件重なる。**
        try await rig.speakOnce(on: run)
        try await waitUntil("2 件目の整形が始まる") { refiner.startedCount >= 2 }

        // 古い方だけ返す。世代は 2 件目の挿入で進んでいるので、
        // **欄は 1 文字も変わらない**（`.staleEpoch` で断念する）。
        refiner.release(0)
        try await waitUntil("1 件目の顛末が出る") { rig.notices.notices.count >= 1 }
        #expect(
            rig.notices.notices.first == .refinementNotApplied(.staleEpoch),
            "失効したはずの錨で差し替えを撃っている")
        #expect(rig.content == Self.contentWithTwoRaws, "古い方が欄を書き換えた")
    }

    /// **ESC がイベントループに読まれたことを、時間ではなく順序で確かめる。**
    ///
    /// `run()` はイベントを直列に処理するので、この後の押下が録音を始めた時点で
    /// 直前の ESC は処理済みである。**押下だけでは世代は進まない**
    /// （世代が進むのは挿入。`CompositeInserter.insertCapturingAnchor`）ので、
    /// 保留中の錨は失効しない。
    private func drainHotkeyQueue(_ rig: RevisionRig) async throws {
        rig.hotkey.emit(.pressed)
        try await waitUntil("次の押下が録音を始める") {
            if case .recording = await rig.session.state { return true }
            return false
        }
    }

    /// **古い方が片付いても、新しい方は「保留中」のままである。**
    @Test("古い方が片付いても新しい方は保留中として数える")
    func theNewerRevisionStaysPendingAfterTheOlderOneSettles() async throws {
        try await withTempRoot { root in
            let refiner = GatedRefiner(result: RevisionRig.refined)
            let rig = RevisionRig.make(
                root: root, revisionDeadline: .seconds(60), refiner: refiner)
            let collector = rig.notices.follow(rig.session)
            defer { collector.cancel() }
            let run = Task { await rig.session.run() }
            defer { run.cancel() }

            try await overlapTwoRevisions(rig, refiner, on: run)

            #expect(
                await rig.session.canUndo,
                "2 件目が保留中なのに『戻せるものが無い』と言っている")

            refiner.release(1)
            try await waitUntil("2 件目の顛末が出る") { rig.notices.notices.count >= 2 }
            #expect(rig.notices.notices.last == .refinementApplied)
            #expect(rig.content == Self.contentWithRawThenRefined)
        }
    }

    /// **ESC は新しい方に効く。** 効かないと、書き込みが 1 回も起きていない段階での
    /// 取消し（FR-7 の 1 行目 / 基本設計書 §4）が到達不能になる。
    @Test("ESC は 2 件重なっても新しい方を取りやめる")
    func escapeCancelsTheNewerOfTwoOverlappingRevisions() async throws {
        try await withTempRoot { root in
            let refiner = GatedRefiner(result: RevisionRig.refined)
            let rig = RevisionRig.make(
                root: root, revisionDeadline: .seconds(60), refiner: refiner)
            let collector = rig.notices.follow(rig.session)
            defer { collector.cancel() }
            let run = Task { await rig.session.run() }
            defer { run.cancel() }

            try await overlapTwoRevisions(rig, refiner, on: run)

            rig.hotkey.emit(.cancelled)
            try await drainHotkeyQueue(rig)

            refiner.release(1)
            try await waitUntil("2 件目の顛末が出る") { rig.notices.notices.count >= 2 }

            #expect(
                rig.notices.notices.last == .refinementNotApplied(nil),
                "取りやめたのに差し替えを撃っている")
            #expect(rig.content == Self.contentWithTwoRaws, "取りやめたのに欄を書き換えた")
        }
    }

    /// **Undo キーも新しい方の取りやめとして効く**（FR-7 の 1 行目）。
    ///
    /// 持ち手が消えていると `pendingRevision == nil` かつ `undoAnchor == nil` になり、
    /// **クリップボードへの縮退**（`offerRawTextToClipboard`）へ落ちる。
    /// 生テキストは欄にあるので発話は失われないが、
    /// **取りやめのつもりの打鍵が、利用者のクリップボードを奪いにいく。**
    @Test("Undo キーは 2 件重なっても新しい方を取りやめる")
    func undoKeyCancelsTheNewerOfTwoOverlappingRevisions() async throws {
        try await withTempRoot { root in
            let refiner = GatedRefiner(result: RevisionRig.refined)
            let rig = RevisionRig.make(
                root: root, revisionDeadline: .seconds(60), refiner: refiner)
            let collector = rig.notices.follow(rig.session)
            defer { collector.cancel() }
            let run = Task { await rig.session.run() }
            defer { run.cancel() }

            try await overlapTwoRevisions(rig, refiner, on: run)

            rig.hotkey.emit(.undoRequested)
            try await waitUntil("Undo の顛末が出る") { rig.notices.notices.count >= 2 }

            #expect(
                rig.notices.notices.last == .undone,
                "保留中の差し替えがあるのに縮退（クリップボード）へ落ちている")
            #expect(rig.clipboard.left.isEmpty, "取りやめのつもりの打鍵でクリップボードを奪った")

            refiner.release(1)
            try await waitUntil("2 件目の顛末が出る") { rig.notices.notices.count >= 3 }
            #expect(rig.notices.notices.last == .refinementNotApplied(nil))
            #expect(rig.content == Self.contentWithTwoRaws, "取りやめたのに欄を書き換えた")
        }
    }

    /// **古い方へ届いた ESC が、新しい方の差し替えを巻き添えにしない。**
    ///
    /// 取りやめを持ち主で照合するようにしたので、**照合の向きを間違えると
    /// 次の発話の整形が黙って落ちる**（利用者から見れば「整形が効かない」）。
    /// 縮退先は生テキストなので発話は失われないが、機能が静かに死ぬ。
    @Test("古い方への ESC は新しい方の差し替えを止めない")
    func cancellingTheOlderRevisionDoesNotStopTheNewerOne() async throws {
        try await withTempRoot { root in
            let refiner = GatedRefiner(result: RevisionRig.refined)
            let rig = RevisionRig.make(
                root: root, revisionDeadline: .seconds(60), refiner: refiner)
            let collector = rig.notices.follow(rig.session)
            defer { collector.cancel() }
            let run = Task { await rig.session.run() }
            defer { run.cancel() }

            try await rig.speakOnce(on: run)
            try await waitUntil("1 件目の整形が始まる") { refiner.startedCount >= 1 }

            // 保留が 1 件だけの状態で ESC（既存の経路）。
            rig.hotkey.emit(.cancelled)
            try await drainHotkeyQueue(rig)

            // そのまま 2 件目を通す（`drainHotkeyQueue` の押下を使う）。
            rig.audio.emit(frames: 1_600)
            rig.hotkey.emit(.released)
            try await waitUntil("2 件目の挿入が終わる") { rig.history.entries.count >= 2 }
            try await waitUntil("2 件目の整形が始まる") { refiner.startedCount >= 2 }

            refiner.release(0)
            refiner.release(1)
            try await waitUntil("2 件の顛末が出る") { rig.notices.notices.count >= 2 }

            #expect(
                rig.notices.notices.contains(.refinementApplied),
                "古い方への ESC が新しい方の差し替えまで落とした")
            #expect(rig.content == Self.contentWithRawThenRefined)
        }
    }
}
