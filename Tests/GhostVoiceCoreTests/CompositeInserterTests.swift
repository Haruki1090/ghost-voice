import Testing
import ApplicationServices
import AppKit
import Foundation
@testable import GhostVoiceCore

@Suite("CompositeInserter")
struct CompositeInserterTests {

    /// 3 段すべてを偽物で組んだ合成器。**本物のクリップボードにもキー送出にも触れない。**
    /// 開発機で `swift test` を回してクリップボードが壊れたり、フォアグラウンドの
    /// アプリへ ⌘V が飛んだりしてはならない。
    private func makeComposite(
        primary: StubInserter, fallback: StubInserter
    ) -> (CompositeInserter, StubClipboard) {
        let clipboard = StubClipboard()
        return (
            CompositeInserter(primary: primary, fallback: fallback, lastResort: clipboard),
            clipboard
        )
    }

    @Test("AX が使えるなら AX 経路になる")
    func usesAXWhenPossible() async {
        let (composite, _) = makeComposite(
            primary: StubInserter(canInsert: true, succeeds: true),
            fallback: StubInserter(canInsert: true, succeeds: true)
        )
        #expect(await composite.insert("テキスト") == .ax)
    }

    @Test("AX が適用外なら Pasteboard 経路になる")
    func fallsBackWhenAXUnavailable() async {
        let (composite, _) = makeComposite(
            primary: StubInserter(canInsert: false, succeeds: true),
            fallback: StubInserter(canInsert: true, succeeds: true)
        )
        #expect(await composite.insert("テキスト") == .pasteboard)
    }

    @Test("AX が失敗したら Pasteboard 経路へ落ちる")
    func fallsBackWhenAXFails() async {
        let (composite, _) = makeComposite(
            primary: StubInserter(canInsert: true, succeeds: false),
            fallback: StubInserter(canInsert: true, succeeds: true)
        )
        #expect(await composite.insert("テキスト") == .pasteboard)
    }

    @Test("両方失敗したら clipboardOnly になる")
    func reportsClipboardOnlyWhenBothFail() async {
        let (composite, _) = makeComposite(
            primary: StubInserter(canInsert: true, succeeds: false),
            fallback: StubInserter(canInsert: true, succeeds: false)
        )
        #expect(await composite.insert("テキスト") == .clipboardOnly)
    }

    /// **このプロジェクトで最も重い不変条件。** 音声は再現できないので、挿入が全滅しても
    /// 発話はクリップボードに残っていなければならない（基本設計書 §230、詳細設計書 §6.4）。
    ///
    /// `.clipboardOnly` という戻り値だけを見るテストではこれを検査できない。戻り値は
    /// 「クリップボードへ残した」と主張しているだけで、実際に残したかは別の話である。
    /// 残置そのものを見る。
    @Test("両方失敗してもテキストをクリップボードへ残す")
    func leavesTextOnClipboardWhenBothFail() async {
        let (composite, clipboard) = makeComposite(
            primary: StubInserter(canInsert: true, succeeds: false),
            fallback: StubInserter(canInsert: true, succeeds: false)
        )

        #expect(await composite.insert("失われては困る発話") == .clipboardOnly)
        #expect(clipboard.left == ["失われては困る発話"])
    }

    /// 両段が「適用外」を返した場合も同じく残さねばならない。`canInsert()` が false の
    /// 経路では `tryInsert` が走らないため、`PasteboardInserter` がクリップボードへ
    /// 書く機会そのものが無い。ここを塞がないと発話が消える。
    @Test("両段とも適用外ならテキストをクリップボードへ残す")
    func leavesTextOnClipboardWhenNeitherApplies() async {
        let (composite, clipboard) = makeComposite(
            primary: StubInserter(canInsert: false, succeeds: true),
            fallback: StubInserter(canInsert: false, succeeds: true)
        )

        #expect(await composite.insert("失われては困る発話") == .clipboardOnly)
        #expect(clipboard.left == ["失われては困る発話"])
    }

    /// 挿入に成功した場合まで最後の砦を叩くと、ユーザーのクリップボードを毎回
    /// 上書きすることになる。成功時は触ってはならない。
    @Test("挿入に成功したらクリップボードへは残さない")
    func doesNotTouchClipboardOnSuccess() async {
        for fallbackCanInsert in [true, false] {
            let (axPath, clipboard) = makeComposite(
                primary: StubInserter(canInsert: true, succeeds: true),
                fallback: StubInserter(canInsert: fallbackCanInsert, succeeds: true)
            )
            #expect(await axPath.insert("テキスト") == .ax)
            #expect(clipboard.left.isEmpty)
        }

        let (pasteboardPath, clipboard) = makeComposite(
            primary: StubInserter(canInsert: false, succeeds: true),
            fallback: StubInserter(canInsert: true, succeeds: true)
        )
        #expect(await pasteboardPath.insert("テキスト") == .pasteboard)
        #expect(clipboard.left.isEmpty)
    }

    /// 適用可否の判定は「試す前に」効かなければならない。`&&` を `&` に変えるような
    /// 変更は戻り値を一切変えないが、**適用外と分かっている経路で実際に挿入を試みる**。
    /// AX 経路でこれが起きると、対象外の要素へ書き込みを投げることになる。
    /// 戻り値ではなく呼び出しの有無で見る。
    @Test("canInsert が false の段では tryInsert を呼ばない")
    func doesNotTryWhenNotApplicable() async {
        let primary = StubInserter(canInsert: false, succeeds: true)
        let fallback = StubInserter(canInsert: false, succeeds: true)
        let (composite, _) = makeComposite(primary: primary, fallback: fallback)

        _ = await composite.insert("テキスト")

        #expect(primary.calls.canInsertCount == 1)
        #expect(primary.calls.tryInsertCount == 0, "適用外の AX 経路へ書き込みを投げている")
        #expect(fallback.calls.canInsertCount == 1)
        #expect(fallback.calls.tryInsertCount == 0)
    }

    /// AX で入ったのに Pasteboard も走る実装だと、テキストが二重に挿入され、
    /// ユーザーのクリップボードまで書き換わる。先の段が成功したら後段は触らない。
    @Test("先の段が成功したら後の段は呼ばない")
    func stopsAtFirstSuccess() async {
        let primary = StubInserter(canInsert: true, succeeds: true)
        let fallback = StubInserter(canInsert: true, succeeds: true)
        let (composite, _) = makeComposite(primary: primary, fallback: fallback)

        #expect(await composite.insert("テキスト") == .ax)

        #expect(primary.calls.tryInsertCount == 1)
        #expect(fallback.calls.canInsertCount == 0, "AX で入ったのに Pasteboard を評価している")
        #expect(fallback.calls.tryInsertCount == 0, "テキストが二重に挿入される")
    }

    /// 各段へ渡る文字列が挿入対象そのものであること。取り違えや空文字への
    /// すり替えは戻り値には現れない。
    @Test("挿入対象の文字列がそのまま各段へ渡る")
    func passesTextThrough() async {
        let primary = StubInserter(canInsert: true, succeeds: false)
        let fallback = StubInserter(canInsert: true, succeeds: false)
        let (composite, clipboard) = makeComposite(primary: primary, fallback: fallback)

        _ = await composite.insert("えーっと、来週までに要件定義を完了させます")

        #expect(primary.calls.insertedTexts == ["えーっと、来週までに要件定義を完了させます"])
        #expect(fallback.calls.insertedTexts == ["えーっと、来週までに要件定義を完了させます"])
        #expect(clipboard.left == ["えーっと、来週までに要件定義を完了させます"])
    }

    /// 空文字でも経路の判定は同じでなければならない。`text.isEmpty` で早期に
    /// 抜ける実装を入れると、履歴に記録される経路が実態とずれる。
    @Test("空文字でも経路の判定は変わらない")
    func handlesEmptyText() async {
        let (composite, _) = makeComposite(
            primary: StubInserter(canInsert: true, succeeds: true),
            fallback: StubInserter(canInsert: true, succeeds: true)
        )
        #expect(await composite.insert("") == .ax)
    }
}

@Suite("CompositeInserter.system の組み立て")
struct CompositeInserterAssemblyTests {

    /// 本番の組み合わせは「AX を試し、駄目なら Pasteboard、最後にクリップボード残置」。
    /// **最後の砦は Pasteboard 経路と同じクリップボードでなければならない。** 別の
    /// `NSPasteboard` を掴んだ最後の砦を組むと、残したテキストが誰にも見えない場所へ行く。
    ///
    /// 3 段を個別に検査しても組み立てを間違えれば意味が無いので、本番の組み立てを
    /// そのまま通す。AX とキー送出だけは差し替える（実機の権限の有無で結果が変わる
    /// テストにしないため。権限のある機体では本物の AX がフォアグラウンドのアプリへ
    /// 書き込んでしまう）。
    @Test("system() は挿入が全滅したとき自分のクリップボードへテキストを残す")
    func systemLeavesTextOnItsOwnPasteboard() async {
        try? await withNamedPasteboard { pasteboard in
            let composite = CompositeInserter.system(
                accessibility: FakeAccessibility(focused: nil),
                pasteboard: pasteboard,
                sender: StubPasteShortcutSender(canSend: false)
            )

            #expect(await composite.insert("最後の砦") == .clipboardOnly)
            #expect(pasteboard.string(forType: .string) == "最後の砦")
        }
    }

    /// **段の順序が逆でも「挿入は成功する」ので、結果だけを見ると差が出ない。**
    /// しかし Pasteboard を先に置くと、AX で静かに入れられた場面でも毎回
    /// ユーザーのクリップボードを奪い、⌘V を撒くことになる。順序そのものを固定する。
    @Test("system() は AX を先に試す")
    func systemPrefersAccessibility() async {
        await withNamedPasteboard { pasteboard in
            pasteboard.clearContents()
            _ = pasteboard.setString("ユーザーの内容", forType: .string)

            // AX でも Pasteboard でも挿入できる状況を作る。順序でしか結果が変わらない。
            let sender = StubPasteShortcutSender(canSend: true, observing: pasteboard)
            let composite = CompositeInserter.system(
                accessibility: FakeAccessibility(focused: FakeAccessibility.Element(
                    role: kAXTextFieldRole as String, isSelectedTextSettable: true,
                    processIdentifier: 424_242, acceptsWrite: true
                )),
                pasteboard: pasteboard,
                sender: sender
            )

            #expect(await composite.insert("テキスト") == .ax)
            #expect(sender.calls.sendCount == 0, "AX で入るのに ⌘V を撒いている")
            #expect(
                pasteboard.string(forType: .string) == "ユーザーの内容",
                "AX で入るのにクリップボードを奪っている"
            )
        }
    }
}
