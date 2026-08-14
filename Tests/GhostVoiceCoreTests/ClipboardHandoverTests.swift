import Foundation
import Synchronization
import Testing

@testable import GhostVoiceCore

// MARK: - 検査用の道具

/// **挿入がまだ終わっていない窓を作るための二段目。**
///
/// 本番の二段目（`PasteboardInserter`）は
/// 「クリップボードを退避 → 貼り付け → **既定 300 ms 待つ** → 復元」の順で動き、
/// **その待ちのあいだ `DictationSession` の actor は解放されている。**
/// 代役が即座に返ってしまうと、この窓へ何かが割り込む経路を検査から駆動できない。
///
/// `tryInsert` は `release()` が来るまで返らない。
final class GatedInserter: PrimaryInserting, @unchecked Sendable {

    private struct State {
        var entered = 0
        var released = 0
        var waiting: [Int: CheckedContinuation<Void, Never>] = [:]
    }

    private let state = Mutex(State())

    /// これまでに `tryInsert` へ入った回数。**検査はここを目印に窓へ割り込む。**
    var enteredCount: Int { state.withLock { $0.entered } }

    func canInsert() -> Bool { true }

    /// **錨は取れない。** この段は範囲を持てない（設計 opus §2.2 の C-1）ので、
    /// 経路判定は (b)（整形を待ってから挿入する）へ落ちる。
    func canCaptureAnchor() -> Bool { false }

    /// `index` 番目（0 起点）の挿入を終わらせる。
    func release(_ index: Int) {
        let waiting = state.withLock { current -> CheckedContinuation<Void, Never>? in
            current.released = max(current.released, index + 1)
            return current.waiting.removeValue(forKey: index)
        }
        waiting?.resume()
    }

    func tryInsert(_ text: String) async -> InsertionAttempt {
        let index = state.withLock { current -> Int in
            defer { current.entered += 1 }
            return current.entered
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let alreadyReleased = state.withLock { current -> Bool in
                if index < current.released { return true }
                current.waiting[index] = continuation
                return false
            }
            if alreadyReleased { continuation.resume() }
        }
        // **貼り付いたことは確認できない**ので錨は返さない（`.pasteboard` になる）。
        return .inserted(anchor: nil)
    }
}

// MARK: - 検査

/// **クリップボードの持ち主が入れ替わる窓**（最終レビュー 視点1 の B-2）。
///
/// FR-7 の縮退（自動では戻せない発話の生テキストをクリップボードへ取り出す）は、
/// **本番では挿入器とまったく同じ `NSPasteboard` を掴んでいる**
/// （`CompositeInserter.systemStack`）。したがって、次の発話の貼り付けが
/// 復元待ちに入っている最中にここを撃つと、**置いた生テキストが復元に上書きされる。**
/// 利用者は「⌘V で貼れます」に従って**まったく別のものを貼る。**
///
/// - Important: **この経路は差し替え器を本番へ配線するまで到達不能だった。**
///   `clipboard` が nil だったので、縮退は必ず `.undoUnavailable` で戻っていた。
///   配線した結果、本番で初めて生きた。
/// - Note: **世代の錠（`InsertionEpoch`）では塞げない。** 直列化するのは AX の
///   書き込みであって、クリップボードはそこを通らない。
@Suite("FR-7 の縮退と挿入が、クリップボードを取り合わないこと")
struct ClipboardHandoverTests {

    /// 挿入が終わっていない窓で Undo キーを撃つ。
    @Test("挿入がクリップボードを握っている間は、生テキストを取り出さない")
    func doesNotOfferRawTextWhileAnInsertionHoldsTheClipboard() async throws {
        try await withTempRoot { root in
            let gate = GatedInserter()
            // 一段目（AX）は自プロセスを狙わせて使えなくする。**二段目へ落ちる。**
            let rig = RevisionRig.make(
                root: root, focusedProcess: RevisionRig.ownProcess, fallback: gate)
            let collector = rig.notices.follow(rig.session)
            defer { collector.cancel() }
            let run = Task { await rig.session.run() }
            defer { run.cancel() }

            // 発話 1。**縮退の対象になる履歴**（`.pasteboard` かつ整形済み）を作る。
            gate.release(0)
            try await rig.speakOnce(on: run)
            let latest = try #require(rig.history.entries.first)
            #expect(latest.insertionMethod == .pasteboard)
            #expect(latest.isManualUndoFallbackCandidate, "縮退の対象になっていない")

            // 発話 2。**挿入の途中で止める**（本番の 300 ms の復元待ちに当たる）。
            rig.hotkey.emit(.pressed)
            try await waitUntil("録音が始まる") {
                if case .recording = await rig.session.state { return true }
                return false
            }
            rig.audio.emit(frames: 1_600)
            rig.hotkey.emit(.released)
            try await waitUntil("2 件目の挿入が始まる") { gate.enteredCount >= 2 }

            let leftBefore = rig.clipboard.left
            rig.hotkey.emit(.undoRequested)
            try await waitUntil("Undo の顛末が出る") { !rig.notices.notices.isEmpty }

            #expect(
                rig.clipboard.left == leftBefore,
                "挿入が握っている最中のクリップボードへ生テキストを置いた（復元に上書きされる）")
            #expect(
                rig.notices.notices.last == .undoUnavailable,
                "上書きされる置き方をしたのに『取り出しました』と告げている")

            // 発話 2 を終わらせて後始末する。
            gate.release(1)
            try await waitUntil("待機へ戻る") { await rig.session.state == .idle }
        }
    }

    /// **挿入が終わっていれば従来どおり取り出す。** 上の門が広すぎないことを固定する。
    @Test("挿入が終わっていれば生テキストを取り出す")
    func offersRawTextOnceTheInsertionHasFinished() async throws {
        try await withTempRoot { root in
            let gate = GatedInserter()
            let rig = RevisionRig.make(
                root: root, focusedProcess: RevisionRig.ownProcess, fallback: gate)
            let collector = rig.notices.follow(rig.session)
            defer { collector.cancel() }
            let run = Task { await rig.session.run() }
            defer { run.cancel() }

            gate.release(0)
            try await rig.speakOnce(on: run)
            try await waitUntil("待機へ戻る") { await rig.session.state == .idle }

            rig.hotkey.emit(.undoRequested)
            try await waitUntil("Undo の顛末が出る") { !rig.notices.notices.isEmpty }

            #expect(rig.notices.notices.last == .undoCopiedRawTextToClipboard)
            #expect(rig.clipboard.left.last == RevisionRig.raw)
        }
    }
}
