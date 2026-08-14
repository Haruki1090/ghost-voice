import AppKit
import Foundation
import Testing

@testable import GhostVoiceCore

/// **窓を開いたまま発話しても、⌘V が Ghost Voice 自身へ飛ばないこと。**
///
/// 設定画面や履歴画面を開くと `AppWindow.present()` が `NSApp.activate()` するので、
/// **最前面は Ghost Voice になる。** PTT は `CGEventTap` なので、その状態でも録音は始まる。
///
/// 一段目（AX）は `isSafeTarget` で自プロセスを弾いていた。
/// **二段目（Pasteboard）は挿入先を一切見ておらず**、`sender.canSend`（TCC + secure input）
/// だけで真を返していたので、**⌘V が自分の窓へ配送されていた**——
/// ユーザー辞書の入力欄にフォーカスがあれば発話がそこへ貼られ、
/// 無ければどこにも入らないのに、**どちらも履歴には `.pasteboard` として成功記録された**
/// （最終レビュー 視点1 の B-1 / 視点3 の指摘 1）。
///
/// FR-9 の再挿入は同じ危険を `FocusHandback` で構造的に塞いでいたのに、
/// **本番の発話経路には門が無かった。**
@Suite("挿入先が自分自身のときの門")
struct SelfInsertionGateTests {

    private static let ownProcess: pid_t = 4_242
    private static let otherProcess: pid_t = 424_242

    private func makeInserter(
        frontmost: pid_t?, sender: StubPasteShortcutSender, pasteboard: NSPasteboard
    ) -> PasteboardInserter {
        PasteboardInserter(
            pasteboard: pasteboard, sender: sender,
            restoreDelay: .milliseconds(1),
            ownProcessIdentifier: Self.ownProcess,
            frontmostProcessIdentifier: { frontmost })
    }

    @Test("最前面が Ghost Voice 自身なら、Pasteboard 経路は適用外になる")
    func refusesWhenGhostVoiceIsFrontmost() async {
        await withNamedPasteboard { board in
            let sender = StubPasteShortcutSender(canSend: true)
            let inserter = makeInserter(
                frontmost: Self.ownProcess, sender: sender, pasteboard: board)

            #expect(!inserter.canInsert(), "自分の窓へ ⌘V を送ろうとしている")
            #expect(sender.calls.sendCount == 0)
        }
    }

    @Test("最前面が別のアプリなら、今までどおり適用できる")
    func allowsWhenAnotherAppIsFrontmost() async {
        await withNamedPasteboard { board in
            let sender = StubPasteShortcutSender(canSend: true)
            let inserter = makeInserter(
                frontmost: Self.otherProcess, sender: sender, pasteboard: board)

            #expect(inserter.canInsert())
        }
    }

    /// 最前面が判らないときは弾かない。
    ///
    /// **門の根拠は「自分である」ことだけ**である（AX 経路が不明な相手を弾くのは
    /// 「自プロセスへの書き込みが永久にブロックする」という別の理由による）。
    /// 判らないという理由で弾くと、**判定が壊れた瞬間に挿入が全部止まる。**
    @Test("最前面が判らないときは弾かない")
    func allowsWhenTheFrontmostProcessIsUnknown() async {
        await withNamedPasteboard { board in
            let sender = StubPasteShortcutSender(canSend: true)
            let inserter = makeInserter(
                frontmost: nil, sender: sender, pasteboard: board)

            #expect(inserter.canInsert())
        }
    }

    /// **合成器を通した結末。** 自分の窓が前面なら、
    /// AX も Pasteboard も適用外になり、**クリップボードへの残置へ落ちる。**
    /// 発話は失われず、⌘V は 1 度も送られない。
    @Test("窓を開いたまま発話すると、⌘V を送らずクリップボードへ残す")
    func fallsBackToTheClipboardInsteadOfPastingIntoItself() async {
        await withNamedPasteboard { board in
            let sender = StubPasteShortcutSender(canSend: true)
            let pasteboardInserter = makeInserter(
                frontmost: Self.ownProcess, sender: sender, pasteboard: board)
            // 一段目は自プロセスを弾く（既にそうなっている）。
            let element = FakeAccessibility.Element(
                role: kAXTextAreaRole as String, isSelectedTextSettable: true,
                processIdentifier: Self.ownProcess, acceptsWrite: true)
            let composite = CompositeInserter(
                primary: AccessibilityInserter(
                    accessibility: FakeAccessibility(focused: element, field: FakeTextField()),
                    ownProcessIdentifier: Self.ownProcess),
                fallback: pasteboardInserter,
                lastResort: pasteboardInserter,
                isSecureInputEnabled: { false }
            )

            let outcome = await composite.insert("設定画面を開いたまま喋った発話")

            #expect(outcome == .inserted(.clipboardOnly))
            #expect(sender.calls.sendCount == 0, "自分の窓へ ⌘V を送っている")
            #expect(
                board.string(forType: .string) == "設定画面を開いたまま喋った発話",
                "発話がクリップボードに残っていない")
            #expect(
                outcome.recordableMethod == .clipboardOnly,
                "自分の窓へ入った（かもしれない）ものを `.pasteboard` 成功として記録している")
        }
    }

    /// **本番の組み立て（`systemStack`）にも門が入っていること。**
    ///
    /// 門を `PasteboardInserter` に足しただけでは足りない——
    /// **本番の組み立てがそれを渡していなければ、欠陥は本番だけで復活する**
    /// （フェーズ 2 の最大の欠陥がまさにその形だった）。
    @Test("本番の組み立ては自プロセスの判定を通す")
    func theProductionStackCarriesTheGate() async {
        await withNamedPasteboard { board in
        let sender = StubPasteShortcutSender(canSend: true)
        let element = FakeAccessibility.Element(
            role: kAXTextAreaRole as String, isSelectedTextSettable: true,
            processIdentifier: Self.ownProcess, acceptsWrite: true)
        let stack = CompositeInserter.systemStack(
            accessibility: FakeAccessibility(focused: element, field: FakeTextField()),
            pasteboard: board,
            sender: sender,
            restoreDelay: .milliseconds(1),
            ownProcessIdentifier: Self.ownProcess,
            frontmostProcessIdentifier: { Self.ownProcess },
            isSecureInputEnabled: { false })

        let outcome = await stack.inserter.insert("設定画面を開いたまま喋った発話")

        #expect(outcome == .inserted(.clipboardOnly))
        #expect(sender.calls.sendCount == 0, "本番の組み立てに門が渡っていない")
        }
    }
}
