import ApplicationServices
import CoreGraphics
import Foundation
import Testing

@testable import GhostVoiceCore

/// FR-7。**Undo は差し替えと同じ原始操作を逆向きに使うだけである。**
@Suite("FR-7: Undo の実行")
struct UndoExecutionTests {

    /// 1 発話ぶんを流し、差し替えまで終わらせる。**その後 Undo を撃てる状態になる。**
    private func speakAndRevise(_ rig: RevisionRig) async throws -> Task<Void, Never> {
        let collector = rig.notices.follow(rig.session)
        let run = Task { await rig.session.run() }

        rig.hotkey.emit(.pressed)
        try await waitUntil("録音が始まる") {
            if case .recording = await rig.session.state { return true }
            return false
        }
        rig.audio.emit(frames: 1_600)
        rig.hotkey.emit(.released)
        try await waitUntil("差し替えが終わる") { !rig.notices.notices.isEmpty }
        _ = collector
        return run
    }

    @Test("差し替えた直後の Undo は生テキストへ戻す")
    func undoRestoresRawText() async throws {
        try await withTempRoot { root in
            let rig = RevisionRig.make(root: root)
            let run = try await speakAndRevise(rig)
            defer { run.cancel() }
            #expect(rig.content == RevisionRig.contentWithRefined)

            rig.hotkey.emit(.undoRequested)
            try await waitUntil("戻る") { rig.notices.notices.count >= 2 }

            #expect(rig.content == RevisionRig.contentWithRaw)
            #expect(rig.notices.notices.last == .undone)
        }
    }

    /// **一度きり。** 二度目を通すと、戻した先をさらに書き換えることになる。
    @Test("Undo は一度しか効かない")
    func undoAppliesOnlyOnce() async throws {
        try await withTempRoot { root in
            let rig = RevisionRig.make(root: root)
            let run = try await speakAndRevise(rig)
            defer { run.cancel() }

            rig.hotkey.emit(.undoRequested)
            try await waitUntil("戻る") { rig.notices.notices.count >= 2 }
            rig.hotkey.emit(.undoRequested)
            try await waitUntil("2 度目の顛末が出る") { rig.notices.notices.count >= 3 }

            #expect(rig.content == RevisionRig.contentWithRaw, "二度戻している")
            #expect(rig.notices.notices.last == .undoUnavailable)
            #expect(await rig.session.canUndo == false)
        }
    }

    /// **Undo も挿入経路を通る。** したがって secure input 中は同じ判定で拒否される。
    /// パスワード欄で「戻す」を撃たれても、そこへは 1 文字も書かない。
    @Test("secure input 中の Undo は拒否される")
    func undoIsRefusedWhileSecureInputIsEnabled() async throws {
        try await withTempRoot { root in
            let rig = RevisionRig.make(root: root)
            let run = try await speakAndRevise(rig)
            defer { run.cancel() }

            rig.isSecureInput.enable()
            rig.hotkey.emit(.undoRequested)
            try await waitUntil("顛末が出る") { rig.notices.notices.count >= 2 }

            #expect(rig.content == RevisionRig.contentWithRefined, "パスワード欄で書き換えている")
            #expect(rig.notices.notices.last == .undoDeclined(.secureInput))
        }
    }

    @Test("利用者が編集した後の Undo は断念する")
    func undoDeclinesAfterTheUserEdited() async throws {
        try await withTempRoot { root in
            let rig = RevisionRig.make(root: root)
            let run = try await speakAndRevise(rig)
            defer { run.cancel() }

            let edited = RawTextFirstInsertionTests.userRewrite
            rig.apply(.userEdits(edited))
            rig.hotkey.emit(.undoRequested)
            try await waitUntil("顛末が出る") { rig.notices.notices.count >= 2 }

            #expect(rig.content == edited, "利用者が書いたものを壊している")
            #expect(rig.notices.notices.last == .undoDeclined(.sourceMismatch))
        }
    }

    /// **保留中の差し替えに対する Undo は「取りやめるだけ」である**（FR-7 の細目 1 行目）。
    /// 書き込みが 1 回も起きないので危険度はゼロ。
    @Test("保留中の差し替えは Undo で取りやめられる")
    func undoCancelsAPendingRevision() async throws {
        try await withTempRoot { root in
            let rig = RevisionRig.make(root: root, refineDelay: .milliseconds(300))
            let collector = rig.notices.follow(rig.session)
            defer { collector.cancel() }
            let run = Task { await rig.session.run() }
            defer { run.cancel() }

            rig.hotkey.emit(.pressed)
            try await waitUntil("録音が始まる") {
                if case .recording = await rig.session.state { return true }
                return false
            }
            rig.audio.emit(frames: 1_600)
            rig.hotkey.emit(.released)
            try await waitUntil("生テキストが挿入される") { !rig.history.entries.isEmpty }

            rig.hotkey.emit(.undoRequested)
            try await waitUntil("顛末が出る") { rig.notices.notices.count >= 2 }

            #expect(rig.content == RevisionRig.contentWithRaw, "取りやめたのに書き換えている")
            #expect(rig.notices.notices.first == .undone)
        }
    }

    /// **戻せるものが無いときは何もしない。**
    @Test("戻せるものが無ければ何もしない")
    func undoWithoutATargetDoesNothing() async throws {
        try await withTempRoot { root in
            let rig = RevisionRig.make(root: root)
            let collector = rig.notices.follow(rig.session)
            defer { collector.cancel() }
            let run = Task { await rig.session.run() }
            defer { run.cancel() }

            rig.hotkey.emit(.undoRequested)
            try await waitUntil("顛末が出る") { !rig.notices.notices.isEmpty }

            #expect(rig.content == RevisionRig.prefix + RevisionRig.suffix, "何かを書き換えた")
            #expect(rig.notices.notices == [.undoUnavailable])
        }
    }

    /// **`.clipboardOnly` の発話へ Undo を撃たない**（持ち越し項目 16）。
    ///
    /// **どこにも挿入していない発話である。** そこへ差し替えを撃つと、
    /// 挿入していないテキストを消そうとして**別の何かを消す。**
    /// 錨は `.ax` 経路でしか作られないので、この経路は構造的に存在しない——
    /// 代わりに**生テキストをクリップボードへ取り出す**縮退になる（FR-7 の細目 3 行目）。
    @Test("挿入していない発話へ Undo を撃たない")
    func neverUndoesAClipboardOnlyUtterance() async throws {
        try await withTempRoot { root in
            // 自プロセスを狙わせて AX 経路を使えなくする＝`.clipboardOnly` へ落ちる。
            let rig = RevisionRig.make(root: root, focusedProcess: RevisionRig.ownProcess)
            let collector = rig.notices.follow(rig.session)
            defer { collector.cancel() }
            let run = Task { await rig.session.run() }
            defer { run.cancel() }

            rig.hotkey.emit(.pressed)
            try await waitUntil("録音が始まる") {
                if case .recording = await rig.session.state { return true }
                return false
            }
            rig.audio.emit(frames: 1_600)
            rig.hotkey.emit(.released)
            try await waitUntil("待機へ戻る") { await rig.session.state == .idle }
            let entry = try #require(rig.history.entries.first)
            #expect(entry.insertionMethod == .clipboardOnly)
            #expect(entry.isAutomaticUndoCandidate == false, "候補になってはならない")

            let contentBefore = rig.content
            rig.hotkey.emit(.undoRequested)
            try await waitUntil("顛末が出る") { !rig.notices.notices.isEmpty }

            // **欄は 1 文字も変わらない。**
            #expect(rig.content == contentBefore)
            // 縮退は「生テキストをクリップボードへ取り出す」。
            #expect(rig.notices.notices == [.undoCopiedRawTextToClipboard])
            #expect(rig.clipboard.left.last == RevisionRig.raw)
        }
    }

    /// **クリップボードへの取り出しにも secure input の判定を掛ける。**
    ///
    /// `offerRawTextToClipboard()` は、挿入・差し替え・Undo 本体・再挿入のうちで
    /// **唯一 secure input の判定を通らない「クリップボードへ置く」経路**だった。
    ///
    /// 到達しないと考えられてはいた——この関数を呼ぶのは Undo キーの打鍵だけで、
    /// **secure input が有効な間は `CGEventTap` にキーイベントが配送されない**ためである。
    /// **しかしそれは偶然の性質に依存した守り方である**（最終レビュー 視点5 の P-4）。
    /// 将来 HUD やメニューから Undo を撃てるようにした瞬間に穴が開く。
    /// **推定に頼らず、判定を置く。**
    @Test("secure input 中は、生テキストをクリップボードへ取り出さない")
    func doesNotOfferRawTextToTheClipboardUnderSecureInput() async throws {
        try await withTempRoot { root in
            let rig = RevisionRig.make(root: root, focusedProcess: RevisionRig.ownProcess)
            let collector = rig.notices.follow(rig.session)
            defer { collector.cancel() }
            let run = Task { await rig.session.run() }
            defer { run.cancel() }

            rig.hotkey.emit(.pressed)
            try await waitUntil("録音が始まる") {
                if case .recording = await rig.session.state { return true }
                return false
            }
            rig.audio.emit(frames: 1_600)
            rig.hotkey.emit(.released)
            try await waitUntil("待機へ戻る") { await rig.session.state == .idle }
            #expect(rig.history.entries.first?.insertionMethod == .clipboardOnly)

            // ここでパスワード欄へ移った。
            rig.isSecureInput.enable()
            let leftBefore = rig.clipboard.left.count
            rig.hotkey.emit(.undoRequested)
            try await waitUntil("顛末が出る") { !rig.notices.notices.isEmpty }

            #expect(
                rig.clipboard.left.count == leftBefore,
                "secure input 中なのに発話をクリップボードへ置いた")
            #expect(rig.notices.notices == [.undoUnavailable])
        }
    }
}

/// 打鍵の判定。**1 打鍵あたり p50 0.75 μs で、これはシステム全体の打鍵に乗る。**
@Suite("FR-7: Undo キーの判定")
struct UndoHotkeyDecisionTests {

    private static let zKeyCode: Int64 = 0x06
    private static let undo = HotkeyBinding.controlCommandZ
    private static var undoFlags: CGEventFlags { [.maskControl, .maskCommand] }

    private func decide(
        type: CGEventType = .keyDown,
        keyCode: Int64 = UndoHotkeyDecisionTests.zKeyCode,
        flags: CGEventFlags = UndoHotkeyDecisionTests.undoFlags,
        undoBinding: HotkeyBinding? = UndoHotkeyDecisionTests.undo,
        isUndoAvailable: Bool = false,
        isRecording: Bool = false,
        isSessionBusy: Bool = false
    ) -> (event: HotkeyEvent?, suppress: Bool) {
        HotkeyDecision.decide(
            type: type, keyCode: keyCode, flags: flags, binding: .rightOption,
            isRecording: isRecording, isSessionBusy: isSessionBusy,
            undoBinding: undoBinding, isUndoAvailable: isUndoAvailable)
    }

    @Test("Undo キーの押下は .undoRequested になる")
    func emitsUndoRequested() {
        #expect(decide().event == .undoRequested)
    }

    /// **判定の門はセッションの錨であって、このフラグではない。**
    /// フラグを門にすると、フラグとセッションがずれた瞬間に打鍵が消える。
    @Test("戻せるものが無くても打鍵は届ける")
    func deliversEvenWhenNothingIsUndoable() {
        #expect(decide(isUndoAvailable: false).event == .undoRequested)
    }

    /// **10 秒窓の外では奪わない。** Ghost Voice は何もしないのだから、
    /// ここで抑止すると**下流アプリの Undo / Redo が理由も無く効かなくなる。**
    @Test("戻せるものが無いときは抑止しない")
    func doesNotSuppressWhenNothingIsUndoable() {
        #expect(decide(isUndoAvailable: false).suppress == false)
    }

    /// **戻せるときは奪う。** 通すと、こちらが戻すのと同時にアプリ自身の Undo も
    /// 走って二重に効く。
    @Test("戻せるときだけ抑止する")
    func suppressesOnlyWhenSomethingIsUndoable() {
        #expect(decide(isUndoAvailable: true).suppress)
    }

    @Test("修飾キーが揃っていなければ素通しする")
    func passesThroughWithoutModifiers() {
        let decision = decide(flags: [], isUndoAvailable: true)
        #expect(decision.event == nil)
        #expect(decision.suppress == false)
    }

    /// 解放は見ない。**見に行くとタップのマスクへ `keyUp` を足すことになり、
    /// システム全体の打鍵の配送量が倍になる。**
    @Test("keyUp では何も起きない")
    func ignoresKeyUp() {
        let decision = decide(type: .keyUp, isUndoAvailable: true)
        #expect(decision.event == nil)
        #expect(decision.suppress == false)
    }

    @Test("Undo のバインドが無ければ何も起きない")
    func doesNothingWithoutABinding() {
        #expect(decide(undoBinding: nil).event == nil)
    }

    /// **中断を優先する。** 取り違えると「挿入するな」が効かず発話が入ってしまう。
    /// Undo が効かないことの害は「戻せない」だけである。
    @Test("Undo を ESC に割り当てても中断が勝つ")
    func cancelWinsOverUndoOnEscape() {
        let escape = try! HotkeyBinding(keyCode: HotkeyDecision.escapeKeyCode, modifiers: [])
        let decision = decide(
            keyCode: HotkeyDecision.escapeKeyCode, flags: [], undoBinding: escape,
            isRecording: true)
        #expect(decision.event == .cancelled)
        #expect(decision.suppress)
    }

    /// PTT のバインドが最優先であることは変わっていない。
    @Test("PTT のバインドは Undo より先に見る")
    func pushToTalkWinsOverUndo() {
        let shared = try! HotkeyBinding(keyCode: 0x06, modifiers: [.control, .command])
        let decision = HotkeyDecision.decide(
            type: .keyDown, keyCode: 0x06, flags: Self.undoFlags, binding: shared,
            isRecording: false, undoBinding: shared, isUndoAvailable: true)
        #expect(decision.event == .pressed)
    }

    /// **録音状態を動かさない。** 録音中に Undo キーを押しても発話は続く。
    @Test("Undo は録音を止めない")
    func undoDoesNotStopRecording() {
        #expect(decide(isRecording: true).event == .undoRequested)
    }
}

/// **クリップボードへ置けなかったときに「取り出しました」と言わないこと。**
@Suite("FR-7: 縮退の告知")
struct UndoFallbackHonestyTests {

    @Test("クリップボードへ置けなかったら「取り出しました」と言わない")
    func doesNotClaimTheClipboardWhenTheOffloadFails() async throws {
        try await withTempRoot { root in
            let rig = RevisionRig.make(
                root: root, focusedProcess: RevisionRig.ownProcess, clipboardSucceeds: false)
            let collector = rig.notices.follow(rig.session)
            defer { collector.cancel() }
            let run = Task { await rig.session.run() }
            defer { run.cancel() }

            rig.hotkey.emit(.pressed)
            try await waitUntil("録音が始まる") {
                if case .recording = await rig.session.state { return true }
                return false
            }
            rig.audio.emit(frames: 1_600)
            rig.hotkey.emit(.released)
            try await waitUntil("待機へ戻る") { await rig.session.state == .idle }

            rig.hotkey.emit(.undoRequested)
            try await waitUntil("顛末が出る") { !rig.notices.notices.isEmpty }

            #expect(
                rig.notices.notices == [.undoUnavailable],
                "クリップボードへ置けていないのに『取り出しました』と告げている")
            #expect(rig.clipboard.left.isEmpty)
        }
    }
}
