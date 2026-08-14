import Testing
import ApplicationServices
import AppKit
import Carbon.HIToolbox
import Foundation
import Synchronization
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
            CompositeInserter(
                primary: primary, fallback: fallback, lastResort: clipboard,
                // 実 API を見に行かせない。他のテストが secure input を切り替えるため、
                // ここが実 API のままだと全体実行でのみ落ちる競合になる。
                isSecureInputEnabled: { false }
            ),
            clipboard
        )
    }

    @Test("AX が使えるなら AX 経路になる")
    func usesAXWhenPossible() async {
        let (composite, _) = makeComposite(
            primary: StubInserter(canInsert: true, succeeds: true),
            fallback: StubInserter(canInsert: true, succeeds: true)
        )
        #expect(await composite.insert("テキスト") == .inserted(.ax))
    }

    @Test("AX が適用外なら Pasteboard 経路になる")
    func fallsBackWhenAXUnavailable() async {
        let (composite, _) = makeComposite(
            primary: StubInserter(canInsert: false, succeeds: true),
            fallback: StubInserter(canInsert: true, succeeds: true)
        )
        #expect(await composite.insert("テキスト") == .inserted(.pasteboard))
    }

    @Test("AX が失敗したら Pasteboard 経路へ落ちる")
    func fallsBackWhenAXFails() async {
        let (composite, _) = makeComposite(
            primary: StubInserter(canInsert: true, succeeds: false),
            fallback: StubInserter(canInsert: true, succeeds: true)
        )
        #expect(await composite.insert("テキスト") == .inserted(.pasteboard))
    }

    @Test("両方失敗したら clipboardOnly になる")
    func reportsClipboardOnlyWhenBothFail() async {
        let (composite, _) = makeComposite(
            primary: StubInserter(canInsert: true, succeeds: false),
            fallback: StubInserter(canInsert: true, succeeds: false)
        )
        #expect(await composite.insert("テキスト") == .inserted(.clipboardOnly))
    }

    /// **このプロジェクトで最も重い不変条件。** 音声は再現できないので、挿入が全滅しても
    /// 発話はクリップボードに残っていなければならない（基本設計書 §7、詳細設計書 §6.4）。
    /// **唯一の例外は secure input 中**（`SecureInputRefusalTests`）。
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

        #expect(await composite.insert("失われては困る発話") == .inserted(.clipboardOnly))
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

        #expect(await composite.insert("失われては困る発話") == .inserted(.clipboardOnly))
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
            #expect(await axPath.insert("テキスト") == .inserted(.ax))
            #expect(clipboard.left.isEmpty)
        }

        let (pasteboardPath, clipboard) = makeComposite(
            primary: StubInserter(canInsert: false, succeeds: true),
            fallback: StubInserter(canInsert: true, succeeds: true)
        )
        #expect(await pasteboardPath.insert("テキスト") == .inserted(.pasteboard))
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

        #expect(await composite.insert("テキスト") == .inserted(.ax))

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
        #expect(await composite.insert("") == .inserted(.ax))
    }
}

/// **secure input が有効な間は挿入そのものを拒否する。**
///
/// secure input が有効なのは、ユーザーがパスワードを入力しているときである。
/// そこへディクテーションを通すと、発話が LLM 整形へ渡り、**履歴ファイルへ平文で
/// 永続化される**（`HistoryStore` は `history.json` に平文の JSON で保存する）。
/// クリップボードへ残すのも同じ問題を持つ。
///
/// **このスイートはこのプロジェクトで唯一「発話を失う」ことを正とする。**
/// 通常は発話を失わないことが最優先だが、パスワードは残す方が害が大きい。
@Suite("secure input 中の挿入の拒否")
struct SecureInputRefusalTests {

    private func makeComposite(
        secureInput: Bool
    ) -> (CompositeInserter, StubInserter, StubInserter, StubClipboard) {
        let primary = StubInserter(canInsert: true, succeeds: true)
        let fallback = StubInserter(canInsert: true, succeeds: true)
        let clipboard = StubClipboard()
        let composite = CompositeInserter(
            primary: primary, fallback: fallback, lastResort: clipboard,
            isSecureInputEnabled: { secureInput }
        )
        return (composite, primary, fallback, clipboard)
    }

    @Test("secure input が有効なら拒否を返す")
    func refusesWhileSecureInputIsEnabled() async {
        let (composite, _, _, _) = makeComposite(secureInput: true)
        #expect(await composite.insert("パスワードかもしれない発話") == .refusedSecureInput)
    }

    /// 拒否は**どの経路も試さない**こと。AX 経路が先に走ってしまえば、
    /// パスワード欄へ実際に書き込まれる。
    @Test("拒否したときはどの経路も試さない")
    func triesNoPathWhenRefusing() async {
        let (composite, primary, fallback, _) = makeComposite(secureInput: true)

        _ = await composite.insert("パスワードかもしれない発話")

        #expect(primary.calls.canInsertCount == 0, "AX 経路を評価している")
        #expect(primary.calls.tryInsertCount == 0, "AX 経路が書き込んでいる")
        #expect(fallback.calls.canInsertCount == 0)
        #expect(fallback.calls.tryInsertCount == 0)
    }

    /// **クリップボードにも残さない。** `.clipboardOnly` へ落とすと、
    /// パスワードがクリップボードに置かれる。残置は拒否の答えではない。
    @Test("拒否したときはクリップボードにも残さない")
    func leavesNothingOnClipboardWhenRefusing() async {
        let (composite, _, _, clipboard) = makeComposite(secureInput: true)

        _ = await composite.insert("パスワードかもしれない発話")

        #expect(clipboard.left.isEmpty, "パスワードをクリップボードへ置いている")
    }

    /// 本番の組み立てでも、実際の `NSPasteboard` が汚れないこと。
    @Test("system() の拒否でもクリップボードは汚れない")
    func systemLeavesPasteboardUntouchedWhenRefusing() async {
        await withNamedPasteboard { pasteboard in
            pasteboard.clearContents()
            _ = pasteboard.setString("ユーザーの内容", forType: .string)

            let composite = CompositeInserter.system(
                accessibility: FakeAccessibility(focused: FakeAccessibility.Element(
                    role: kAXTextFieldRole as String, isSelectedTextSettable: true,
                    processIdentifier: 424_242, acceptsWrite: true
                )),
                pasteboard: pasteboard,
                sender: StubPasteShortcutSender(canSend: true, observing: pasteboard),
                isSecureInputEnabled: { true }
            )

            #expect(await composite.insert("パスワードかもしれない発話") == .refusedSecureInput)
            #expect(pasteboard.string(forType: .string) == "ユーザーの内容")
        }
    }

    /// 拒否は履歴に記録してはならない。**型で表現してある**ので、
    /// `HistoryEntry` が要求する `InsertionMethod` を取り出せない。
    @Test("拒否からは履歴に記録できる経路を取り出せない")
    func refusalHasNoRecordableMethod() {
        #expect(InsertionOutcome.refusedSecureInput.recordableMethod == nil)

        for method in [InsertionMethod.ax, .pasteboard, .clipboardOnly] {
            #expect(InsertionOutcome.inserted(method).recordableMethod == method)
        }
    }

    /// secure input が無効なら、いつもどおり挿入する。
    /// **拒否が常時発動していないこと**を見ないと、上のテスト群は
    /// 「常に拒否する実装」でも全部通ってしまう。
    @Test("secure input が無効なら通常どおり挿入する")
    func insertsNormallyWhenSecureInputIsDisabled() async {
        let (composite, primary, _, clipboard) = makeComposite(secureInput: false)

        #expect(await composite.insert("ふつうの発話") == .inserted(.ax))
        #expect(primary.calls.insertedTexts == ["ふつうの発話"])
        #expect(clipboard.left.isEmpty)
    }

    /// 判定は**毎回**行う。ユーザーはパスワード欄に出入りするので、
    /// 起動時の値を握ったままでは意味が無い。
    @Test("secure input は挿入のたびに見に行く")
    func checksSecureInputOnEveryInsert() async {
        let checks = Atomic<Int>(0)
        let enabled = Atomic<Bool>(false)
        let composite = CompositeInserter(
            primary: StubInserter(canInsert: true, succeeds: true),
            fallback: StubInserter(canInsert: true, succeeds: true),
            lastResort: StubClipboard(),
            isSecureInputEnabled: {
                checks.add(1, ordering: .relaxed)
                return enabled.load(ordering: .relaxed)
            }
        )

        #expect(await composite.insert("一回目") == .inserted(.ax))
        enabled.store(true, ordering: .relaxed)
        #expect(await composite.insert("二回目") == .refusedSecureInput)

        #expect(checks.load(ordering: .relaxed) == 2, "挿入のたびに見ていない")
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
        await withNamedPasteboard { pasteboard in
            let composite = CompositeInserter.system(
                accessibility: FakeAccessibility(focused: nil),
                pasteboard: pasteboard,
                sender: StubPasteShortcutSender(canSend: false),
                isSecureInputEnabled: { false }
            )

            #expect(await composite.insert("最後の砦") == .inserted(.clipboardOnly))
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
                sender: sender,
                isSecureInputEnabled: { false }
            )

            #expect(await composite.insert("テキスト") == .inserted(.ax))
            #expect(sender.calls.sendCount == 0, "AX で入るのに ⌘V を撒いている")
            #expect(
                pasteboard.string(forType: .string) == "ユーザーの内容",
                "AX で入るのにクリップボードを奪っている"
            )
        }
    }
}

/// **実際の secure input を切り替える検査。**
///
/// `EnableSecureEventInput()` は**システム全体の状態**を変える。swift-testing は
/// テストを並列に実行するため、切り替えるテストが複数のスイートに散っていると
/// 「片方が有効化している最中に、もう片方が無効を前提に検査する」競合が起きる。
///
/// **実際にこれで 1 件落ちた。** しかもフィルタ実行では出ず、全体実行でのみ出た。
/// グローバル状態を触る検査はこの 1 スイートに集め、`.serialized` で直列化する。
/// 他のスイートは `isSecureInputEnabled: { false }` を明示注入し、
/// 実 API を見に行かないようにしてある。
@Suite("実際の secure input を切り替える検査", .serialized)
struct RealSecureInputTests {
    /// **指定イニシャライザの既定引数**が実 API を見ていること。
    ///
    /// `system()` 経由の検査（`defaultCompositeUsesRealSecureInputCheck`）だけでは、
    /// `system()` が持つ既定しか通らない。**素の `CompositeInserter(...)` を
    /// secure input の引数なしで組んだ場合の既定**は別の行なので、別に検査が要る
    /// （ミューテーションでこの穴が判明した）。
    ///
    /// - Important: システム全体の状態を一時的に変える。`defer` で釣り合いを取る。
    @Test("secure input の引数を省略した組み立ても実 API を見る")
    func defaultArgumentUsesRealSecureInputCheck() async throws {
        try #require(!IsSecureEventInputEnabled(), "他プロセスが secure input を有効にしている")

        // secure input 以外はすべて挿入できる状態にする。差が出ないと何も検査できない。
        let composite = CompositeInserter(
            primary: StubInserter(canInsert: true, succeeds: true),
            fallback: StubInserter(canInsert: true, succeeds: true),
            lastResort: StubClipboard()
        )
        #expect(await composite.insert("有効化前") == .inserted(.ax))

        try #require(EnableSecureEventInput() == noErr)
        defer { _ = DisableSecureEventInput() }

        #expect(await composite.insert("有効化後") == .refusedSecureInput,
                "既定引数が実際の secure input を見ていない")
    }

    /// 既定の組み立てが実 API を見ていることを、実際に有効化して確かめる
    /// （既定を `{ false }` に差し替える変更を検出するため）。
    ///
    /// - Important: システム全体の状態を一時的に変える。参照カウント方式なので
    ///   `defer` で釣り合いを取る。窓は実測 17 ms。
    @Test("既定の組み立ては実際の secure input を見る")
    func defaultCompositeUsesRealSecureInputCheck() async throws {
        try #require(!IsSecureEventInputEnabled(), "他プロセスが secure input を有効にしている")

        try await withNamedPasteboard { pasteboard in
            // secure input 以外はすべて挿入できる状態にしておく。
            // そうしないと差が出ず、何も検査できない。
            let composite = CompositeInserter.system(
                accessibility: FakeAccessibility(focused: FakeAccessibility.Element(
                    role: kAXTextFieldRole as String, isSelectedTextSettable: true,
                    processIdentifier: 424_242, acceptsWrite: true
                )),
                pasteboard: pasteboard,
                sender: StubPasteShortcutSender(canSend: true)
            )
            #expect(await composite.insert("有効化前") == .inserted(.ax))

            try #require(EnableSecureEventInput() == noErr)
            defer { _ = DisableSecureEventInput() }

            #expect(await composite.insert("有効化後") == .refusedSecureInput,
                    "既定の組み立てが実際の secure input を見ていない")
        }
    }
    /// 既定の組み立てが実 API を見ていること。値そのものは機体の権限状態に依存するので、
    /// **実 API と一致すること**だけを見る（規律: 権限のある機体でも正しく動くこと）。
    @Test("既定の送出器は実 API の状態を映す")
    func defaultSenderReflectsSystemState() {
        let expected = CGPreflightPostEventAccess() && !IsSecureEventInputEnabled()
        #expect(SystemPasteShortcutSender().canSend == expected)
    }

    /// **既定の secure input 判定が本当に `IsSecureEventInputEnabled()` を見ているか**を、
    /// 実際に secure input を有効化して確かめる。
    ///
    /// **送出許可の側は true を注入する。** ここを実 API のままにすると、権限の無い機体では
    /// `canSend` が secure input と無関係にもともと false で、
    /// 「有効化したら false だった」が**何も検査していないアサーション**になる
    /// （実際に一度そう書いて、ミューテーション #49 が生き残ったことで判明した）。
    /// 有効化の前後で値が変わることまで見る。
    ///
    /// - Important: **システム全体の状態を一時的に変える。** `EnableSecureEventInput()` は
    ///   参照カウント方式（実測: 2 回有効化 → 1 回解除では有効のまま、2 回解除で無効）なので、
    ///   `defer` で必ず釣り合いを取る。有効な窓は実測 17 ms。
    ///   プロセスが途中で落ちた場合もプロセス終了時に解除される。
    @Test("secure input を有効にすると既定の判定が送出不可へ変わる")
    func secureInputBlocksDefaultSender() throws {
        try #require(!IsSecureEventInputEnabled(), "他プロセスが secure input を有効にしている")

        // secure input 以外の門は開けておく。閉じたままだと差が出ず、何も検査できない。
        // `isSecureInputEnabled` は既定のまま＝実 API を使う。
        let sender = SystemPasteShortcutSender(
            authorization: PostEventAuthorization(probe: { true })
        )
        #expect(sender.canSend, "有効化前は送れる前提が崩れている")

        try #require(EnableSecureEventInput() == noErr)
        defer { _ = DisableSecureEventInput() }

        #expect(IsSecureEventInputEnabled(), "有効化できていない（前提が崩れている）")
        #expect(!sender.canSend, "既定の判定が secure input を見ていない")
    }
}
