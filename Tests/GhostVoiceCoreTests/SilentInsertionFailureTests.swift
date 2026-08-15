import ApplicationServices
import Foundation
import Testing

@testable import GhostVoiceCore

/// **R-4（AX が成功を返しながら何も入らない）の検知。**
///
/// ## 何を観測したか（2026-08-15 / 実機 / macOS 26.5.2 / M3）
///
/// Google Chrome のページ内にある素の `<input>` は、フォーカス要素として
/// `role=AXTextField` を返し、`kAXSelectedText` は `settable=yes` と答え、
/// `AXUIElementSetAttributeValue` は `.success`(0) を返す。**それでも欄には
/// 1 文字も入らない。**
///
/// ```
/// role=AXTextField  kAXSelectedText settable: yes
/// setSelectedText status: 0 (success)
/// 書込前の選択: loc=8 len=0 → 書込後の選択: loc=8 len=0   ← キャレットが動かない
/// 文字数: 8 → 8                                          ← 1 文字も増えていない
/// [caret,0] の読み取り → 読めた（長さ 0）                  ← 読み戻しには応える
/// [caret,5] の読み取り → unreadable(-25212)               ← 書いたはずの場所に何も無い
/// ```
///
/// これは利用者の実害として現れた——**アンケートフォームへ 2 回喋って 2 回とも入らず、
/// 履歴には 2 件とも `ax`（成功）として残った**（履歴 2026-08-15 21:02:11 / 21:02:16）。
///
/// ## 検知の規則（誤検知の向きを決めている）
///
/// **「キャレットが 1 単位も動いていない」だけでは断定しない。** 書き込みに成功しつつ
/// キャレットを書き込み位置の先頭へ戻す相手（`CaretAfterWrite.startOfRange`）と
/// 区別できないためである。断定するのは次の 3 つがそろったときだけ:
///
/// 1. 書き込みの前後でキャレット（位置と長さ）が完全に一致する
/// 2. 相手が範囲の読み戻しに応える（**長さ 0 の問い合わせ**。中身は 1 文字も明かさない）
/// 3. 書いたはずの場所を読むと、書いたはずの文字列が無い
///
/// **判らない相手は従来どおり成功として扱う。** 誤って二段目（⌘V）へ落とすと
/// 二重挿入になり、入らないことより悪い場合がある（詳細設計書 §6.2）。
@Suite("AX の無言失敗を検知して二段目へ落とす")
struct SilentInsertionFailureTests {

    private static let targetProcess: pid_t = 424_242
    /// 欄に元からある文字。**検知のために 1 文字も書き換えてはならない。**
    private static let existing = "既に書いてある文。"
    private static let raw = "青山学院大学"

    /// 挿入器と、その相手の欄をひと組で作る。
    private struct World {
        let field: FakeTextField
        let accessibility: FakeAccessibility
        let inserter: AccessibilityInserter

        init(
            content: String = SilentInsertionFailureTests.existing,
            selection: AXTextRange? = nil,
            behavior: FakeTextField.WriteBehavior,
            caret: FakeTextField.CaretAfterWrite = .endOfWrittenText,
            respondsToStringForRange: Bool = true
        ) {
            self.field = FakeTextField(
                content: content, selection: selection, behavior: behavior, caret: caret,
                respondsToStringForRange: respondsToStringForRange
            )
            self.accessibility = FakeAccessibility(
                focused: FakeAccessibility.Element(
                    role: kAXTextFieldRole as String, isSelectedTextSettable: true,
                    processIdentifier: SilentInsertionFailureTests.targetProcess,
                    acceptsWrite: true
                ),
                field: field
            )
            self.inserter = AccessibilityInserter(
                accessibility: accessibility, ownProcessIdentifier: getpid()
            )
        }
    }

    /// **これが利用者に起きたことである。** AX は成功を返し、欄には何も入っていない。
    @Test("無言失敗した書き込みを成功として返さない")
    func silentNoOpIsNotReportedAsInserted() async {
        let world = World(behavior: .silentNoOp)

        let attempt = await world.inserter.tryInsert(Self.raw)

        #expect(attempt.didInsert == false, "何も入っていないのに成功を返している")
        #expect(world.field.content == Self.existing, "欄を書き換えている")
    }

    /// 欄の途中（前後に利用者の文字がある位置）でも検知できること。
    /// **末尾での失敗が「範囲外だから読めない」で当たっているだけ**では、
    /// 途中での失敗（別の文字が読めてしまう）を取りこぼす。
    @Test("欄の途中での無言失敗も検知する")
    func silentNoOpInTheMiddleIsDetected() async {
        let world = World(
            content: "前置き。" + "その後に利用者が書いた本文。",
            selection: AXTextRange(location: "前置き。".count, length: 0),
            behavior: .silentNoOp
        )

        #expect(await world.inserter.tryInsert(Self.raw).didInsert == false)
    }

    /// **合成器がこの失敗を受けて二段目（⌘V）を撃つ**ところまでが直しの本体である。
    /// 一段目が `.failed` を返しても二段目が走らなければ、発話は依然として届かない。
    @Test("合成器は無言失敗を二段目へ落とす")
    func compositeFallsBackToPasteboard() async {
        let world = World(behavior: .silentNoOp)
        let fallback = StubInserter(canInsert: true, succeeds: true)
        let clipboard = StubClipboard()
        let composite = CompositeInserter(
            primary: world.inserter, fallback: fallback, lastResort: clipboard,
            isSecureInputEnabled: { false }
        )

        let inserted = await composite.insertCapturingAnchor(Self.raw)

        #expect(inserted.outcome == .inserted(.pasteboard), "二段目へ落ちていない")
        #expect(fallback.calls.insertedTexts == [Self.raw])
        #expect(clipboard.left.isEmpty, "二段目が成功したのに残置している")
    }

    /// 回帰防止。**ふつうに入る相手の挙動は 1 つも変えない。**
    @Test("ふつうに入った書き込みは従来どおり ax のまま")
    func normalWriteStillReportsAX() async {
        let world = World(behavior: .normal)
        let fallback = StubInserter(canInsert: true, succeeds: true)
        let composite = CompositeInserter(
            primary: world.inserter, fallback: fallback, lastResort: StubClipboard(),
            isSecureInputEnabled: { false }
        )

        let inserted = await composite.insertCapturingAnchor(Self.raw)

        #expect(inserted.outcome == .inserted(.ax))
        #expect(inserted.anchor != nil, "錨まで取れるはずの相手で錨が消えている")
        #expect(world.field.content == Self.existing + Self.raw)
        #expect(fallback.calls.tryInsertCount == 0, "成功しているのに二段目を撃っている")
    }

    /// **誤検知の唯一の入口を塞ぐ。** 書き込みに成功しながらキャレットを書き込み位置の
    /// 先頭へ戻す相手は、キャレットだけを見ると無言失敗と見分けがつかない。
    /// **読み戻して「入っている」ことが判るので、二段目へ落としてはならない**
    /// （落とすと同じ文字列が 2 度入る）。
    @Test("キャレットが戻る相手でも、入っていれば成功として扱う")
    func doesNotMisjudgeWhenCaretReturnsToStart() async {
        let world = World(behavior: .normal, caret: .startOfRange)
        let fallback = StubInserter(canInsert: true, succeeds: true)
        let composite = CompositeInserter(
            primary: world.inserter, fallback: fallback, lastResort: StubClipboard(),
            isSecureInputEnabled: { false }
        )

        let inserted = await composite.insertCapturingAnchor(Self.raw)

        #expect(inserted.outcome == .inserted(.ax), "入っているのに二段目へ落としている")
        #expect(world.field.content == Self.existing + Self.raw)
        #expect(fallback.calls.tryInsertCount == 0, "二重挿入になる")
    }

    /// **判らない相手は成功として扱う**（安全側の向き）。範囲の読み戻しに応えない相手では
    /// 「入っていない」ことを確かめる手段が無い。ここを失敗側へ倒すと、
    /// 実際には入っている相手で二重挿入になる。
    @Test("読み戻しに応えない相手では判定しない")
    func doesNotJudgeWhenRangesAreUnreadable() async {
        let world = World(behavior: .silentNoOp, respondsToStringForRange: false)

        #expect(await world.inserter.tryInsert(Self.raw).didInsert == true)
    }

    /// 成功する相手で読み戻しの往復を増やしていないこと（NFR-P5 の予算は 50 ms）。
    /// **検知の費用は失敗した発話だけが払う。**
    @Test("ふつうに入る相手では読み戻しを増やさない")
    func addsNoReadRoundTripOnTheHappyPath() async {
        let world = World(behavior: .normal)

        _ = await world.inserter.tryInsert(Self.raw)

        #expect(world.accessibility.calls.readRanges.count == 1, "錨の確認以外に読んでいる")
    }
}
