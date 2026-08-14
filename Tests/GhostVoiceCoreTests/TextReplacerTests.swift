import Testing
import ApplicationServices
import Foundation
import Synchronization
@testable import GhostVoiceCore

// MARK: - 検査用の道具

/// 告げられたことを覚えておくだけの告知先。
final class RecordingAnnouncer: ReplacementAnnouncing, Sendable {
    private let notices = Mutex<[ReplacementNotice]>([])
    var announced: [ReplacementNotice] { notices.withLock { $0 } }
    func announce(_ notice: ReplacementNotice) { notices.withLock { $0.append(notice) } }
}

/// 差し替えを駆動するための一式。
///
/// **実機のアプリへは一切書き込まない**（安全制約）。欄も AX も告知先もクリップボードも
/// すべて代役で、全経路を決定的に通せる。
struct ReplacementWorld {
    static let targetProcess: pid_t = 424_242
    /// 欄に元からある文字。**差し替えはここへ 1 文字も触れてはならない。**
    static let prefix = "前置きの文。"
    static let suffix = "その後に利用者が書いた本文。"
    static let raw = "えーっと来週までにあの要件定義を完了させます"
    static let refined = "来週までに要件定義を完了させます。"

    let field: FakeTextField
    let accessibility: FakeAccessibility
    let clipboard: StubClipboard
    let announcer: RecordingAnnouncer
    let epoch: InsertionEpoch
    let replacer: TextReplacer
    let anchor: ReplacementAnchor

    /// 錨が指す範囲（`prefix` の直後に `raw` が入っている）。
    static var anchorRange: AXTextRange {
        AXTextRange(location: prefix.count, length: raw.count)
    }

    init(
        behavior: FakeTextField.WriteBehavior = .normal,
        caret: FakeTextField.CaretAfterWrite = .endOfWrittenText,
        respondsToStringForRange: Bool = true,
        selectionWriteFails: Bool = false,
        rangeSettable: Bool = true,
        textSettable: Bool = true,
        acceptsWrite: Bool = true,
        focusedProcess: pid_t = targetProcess,
        anchorProcess: pid_t = targetProcess,
        focusIsSameElement: Bool = true,
        hasFocus: Bool = true,
        secureInput: Bool = false,
        ownProcessIdentifier: pid_t = getpid(),
        anchorText: String = raw,
        userSelection: AXTextRange? = nil
    ) {
        let identity = UUID()
        self.field = FakeTextField(
            content: Self.prefix + Self.raw + Self.suffix,
            selection: userSelection
                ?? AXTextRange(
                    location: Self.prefix.count + Self.raw.count + Self.suffix.count, length: 0),
            behavior: behavior, caret: caret,
            respondsToStringForRange: respondsToStringForRange,
            selectionWriteFails: selectionWriteFails
        )
        let focused = FakeAccessibility.Element(
            role: kAXTextAreaRole as String, isSelectedTextSettable: textSettable,
            processIdentifier: focusedProcess, acceptsWrite: acceptsWrite,
            isSelectedTextRangeSettable: rangeSettable,
            identity: focusIsSameElement ? identity : UUID()
        )
        self.accessibility = FakeAccessibility(focused: hasFocus ? focused : nil, field: field)
        self.clipboard = StubClipboard()
        self.announcer = RecordingAnnouncer()
        self.epoch = InsertionEpoch()
        self.replacer = TextReplacer(
            accessibility: accessibility, clipboard: clipboard, announcer: announcer,
            epoch: epoch, ownProcessIdentifier: ownProcessIdentifier,
            isSecureInputEnabled: { secureInput }
        )
        self.anchor = ReplacementAnchor(
            element: FakeAccessibility.Element(
                role: kAXTextAreaRole as String, isSelectedTextSettable: textSettable,
                processIdentifier: anchorProcess, acceptsWrite: acceptsWrite,
                isSelectedTextRangeSettable: rangeSettable, identity: identity
            ),
            processIdentifier: anchorProcess,
            range: Self.anchorRange, text: anchorText, previousText: nil,
            epoch: epoch.current
        )
    }

    /// 差し替え前の欄の中身。
    static var originalContent: String { prefix + raw + suffix }

    /// **利用者が手で編集した後の欄の中身。**
    ///
    /// 錨の範囲と同じ長さになるよう `seed` を繰り返す。**長さを保つのは、
    /// 「中身が違う」以外の理由（範囲外で読めない）で結果が割れないようにするため。**
    static func editedContent(overwritingRawWith seed: String) -> String {
        let repeated = String(
            String(repeating: seed, count: raw.count / seed.count + 1).prefix(raw.count))
        return prefix + repeated + suffix
    }

    /// **欄が 1 文字も変わっていないこと。**
    var targetIsUntouched: Bool { field.content == Self.originalContent }

    /// `kAXSelectedText` への書き込み回数＝**欄の内容を変えうる操作の回数。**
    var contentWrites: Int { accessibility.calls.writtenTexts.count }
}

// MARK: - 差し替えが成功する経路

@Suite("差し替え: 成功と Undo（FR-5(a) / FR-7 は同じ原始操作）")
struct TextReplacerSuccessTests {

    @Test("成立条件がそろえば、自分が書いた範囲だけを差し替える")
    func replacesOnlyItsOwnRange() {
        let world = ReplacementWorld()

        let result = world.replacer.replace(world.anchor, with: ReplacementWorld.refined)

        #expect(result.didReplace)
        #expect(
            world.field.content
                == ReplacementWorld.prefix + ReplacementWorld.refined + ReplacementWorld.suffix,
            "自分が書いた範囲の外を触っている"
        )
        #expect(world.contentWrites == 1, "内容を変える書き込みは 1 回だけであること")
        #expect(world.clipboard.left.isEmpty, "成功したのにクリップボードを奪っている")
        #expect(world.announcer.announced.isEmpty)
    }

    /// 差し替え後の錨は**新しい範囲**を指し、**直前の文字列**を覚えている。
    /// FR-7 はこれを逆向きに書き戻すだけである。
    @Test("差し替えの結果は、そのまま Undo に使える錨を返す")
    func returnsAnchorUsableForUndo() {
        let world = ReplacementWorld()

        let anchor = world.replacer.replace(world.anchor, with: ReplacementWorld.refined).anchor
        let updated = try! #require(anchor)

        #expect(updated.text == ReplacementWorld.refined)
        #expect(updated.previousText == ReplacementWorld.raw)
        #expect(updated.range.location == ReplacementWorld.anchorRange.location)
        #expect(updated.range.length == ReplacementWorld.refined.count)
    }

    /// **FR-7 は差し替えの逆向きでしかない。** 二重に作っていないことをここで固定する。
    @Test("Undo は同じ原始操作を逆向きに使い、整形前の生テキストへ戻す")
    func undoRestoresRawText() {
        let world = ReplacementWorld()
        let replaced = try! #require(
            world.replacer.replace(world.anchor, with: ReplacementWorld.refined).anchor)

        let undone = world.replacer.undo(replaced)

        #expect(undone.didReplace)
        #expect(world.field.content == ReplacementWorld.originalContent, "生テキストへ戻っていない")
        #expect(undone.anchor?.text == ReplacementWorld.raw)
        #expect(undone.anchor?.previousText == ReplacementWorld.refined)
    }

    /// **挿入しただけの錨へ Undo を撃ってはならない。** 戻す先が無いのに撃つと、
    /// 「挿入していないテキストを消す」形になる（carry-ins 項目 16 と同じ事故）。
    @Test("まだ差し替えていない錨への Undo は何も書き換えない")
    func undoWithoutPreviousTextChangesNothing() {
        let world = ReplacementWorld()

        let result = world.replacer.undo(world.anchor)

        #expect(result.decline == .nothingToUndo)
        #expect(world.targetIsUntouched)
        #expect(world.contentWrites == 0)
    }

    /// 後始末（手順 6）。利用者の選択は、差し替えで縮んだ長さのぶんだけずれる。
    @Test("差し替えた場所より後ろにあった選択は、長さの差だけ補正して戻す")
    func restoresUserSelectionShiftedByLengthDelta() {
        let caretBefore = ReplacementWorld.prefix.count + ReplacementWorld.raw.count + 3
        let world = ReplacementWorld(
            userSelection: AXTextRange(location: caretBefore, length: 0))

        _ = world.replacer.replace(world.anchor, with: ReplacementWorld.refined)

        let delta = ReplacementWorld.refined.count - ReplacementWorld.raw.count
        #expect(
            world.accessibility.calls.writtenRanges.last
                == AXTextRange(location: caretBefore + delta, length: 0)
        )
    }

    @Test("差し替えた場所より前にあった選択は動かさない")
    func keepsUserSelectionBeforeTheRange() {
        let world = ReplacementWorld(userSelection: AXTextRange(location: 2, length: 0))

        _ = world.replacer.replace(world.anchor, with: ReplacementWorld.refined)

        #expect(
            world.accessibility.calls.writtenRanges.last == AXTextRange(location: 2, length: 0))
    }
}

// MARK: - 中止（何も書き換えない）

/// **この製品でいちばん重い不変条件のひとつ。**
///
/// 差し替えは成立条件が 1 つでも欠けたら**何も書き換えない**。縮退先は常に
/// 「挿入済みの生テキストが欄にある」＝**現行実装の正常系そのもの**である。
/// 「差し替えに失敗して消えるだけ」は、この設計には存在してはならない。
@Suite("差し替え: 中止点ではすべて何も書き換えない")
struct TextReplacerDeclineTests {

    /// 中止したときは `kAXSelectedText` への書き込みが 0 回であること。
    /// **戻り値だけを見ても検査できない**（「中止した」と主張しながら書いた可能性が残る）。
    private func expectNothingWritten(
        _ world: ReplacementWorld, _ result: ReplacementResult, _ reason: ReplacementDecline
    ) {
        #expect(result.decline == reason)
        #expect(result.leftTargetUnchanged)
        #expect(world.targetIsUntouched, "中止したのに欄が変わっている")
        #expect(world.contentWrites == 0, "中止したのに書き込んでいる")
        #expect(world.clipboard.left.isEmpty, "中止でクリップボードを奪っている")
    }

    /// **利用者が手で編集していた場合。** 位置の算術を信じず、読み戻して一致したときだけ書く
    /// （設計 opus §2.2 の C-6）。一致しなければ理由を問わず中止する。
    @Test("利用者が編集していたら何も書き換えない")
    func declinesWhenUserEditedTheText() {
        let world = ReplacementWorld()
        let edited = ReplacementWorld.editedContent(overwritingRawWith: "利")
        world.field.userEdits(to: edited)

        let result = world.replacer.replace(world.anchor, with: ReplacementWorld.refined)

        #expect(result.decline == .sourceMismatch)
        #expect(world.field.content == edited, "利用者の編集を壊している")
        #expect(world.contentWrites == 0)
        #expect(world.clipboard.left.isEmpty)
    }

    /// 欄が短くなっていて範囲そのものが取れない場合も、同じく**何も書き換えない。**
    @Test("欄が縮んでいたら何も書き換えない")
    func declinesWhenTheFieldShrank() {
        let world = ReplacementWorld()
        world.field.userEdits(to: "短い")

        let result = world.replacer.replace(world.anchor, with: ReplacementWorld.refined)

        #expect(result.leftTargetUnchanged)
        #expect(world.field.content == "短い", "利用者の編集を壊している")
        #expect(world.contentWrites == 0)
        #expect(world.clipboard.left.isEmpty)
    }

    @Test("読み戻せない相手には何も書き換えない")
    func declinesWhenRangeIsUnreadable() {
        let world = ReplacementWorld(respondsToStringForRange: false)
        expectNothingWritten(
            world, world.replacer.replace(world.anchor, with: ReplacementWorld.refined),
            .sourceUnreadable)
    }

    /// **別アプリへ移ってから撃つと、他人の入力欄を壊す**（carry-ins §6 (c)）。
    @Test("別アプリへ移っていたら何も書き換えない")
    func declinesWhenFrontmostProcessChanged() {
        let world = ReplacementWorld(focusedProcess: 999_999)
        expectNothingWritten(
            world, world.replacer.replace(world.anchor, with: ReplacementWorld.refined),
            .processChanged)
    }

    @Test("同じアプリでも別の入力欄なら何も書き換えない")
    func declinesWhenFocusMovedToAnotherField() {
        let world = ReplacementWorld(focusIsSameElement: false)
        expectNothingWritten(
            world, world.replacer.replace(world.anchor, with: ReplacementWorld.refined),
            .focusChanged)
    }

    @Test("フォーカスが取れなければ何も書き換えない")
    func declinesWithoutFocus() {
        let world = ReplacementWorld(hasFocus: false)
        expectNothingWritten(
            world, world.replacer.replace(world.anchor, with: ReplacementWorld.refined),
            .focusChanged)
    }

    @Test("選択範囲が書き込み可能でなければ何も書き換えない")
    func declinesWhenRangeIsNotSettable() {
        let world = ReplacementWorld(rangeSettable: false)
        expectNothingWritten(
            world, world.replacer.replace(world.anchor, with: ReplacementWorld.refined),
            .rangeNotSettable)
    }

    @Test("選択テキストが書き込み可能でなければ何も書き換えない")
    func declinesWhenSelectedTextIsNotSettable() {
        let world = ReplacementWorld(textSettable: false)
        expectNothingWritten(
            world, world.replacer.replace(world.anchor, with: ReplacementWorld.refined),
            .rangeNotSettable)
    }

    @Test("範囲の設定が失敗したら何も書き換えない")
    func declinesWhenSettingRangeFails() {
        let world = ReplacementWorld(selectionWriteFails: true)
        expectNothingWritten(
            world, world.replacer.replace(world.anchor, with: ReplacementWorld.refined),
            .rangeWriteFailed)
    }

    /// 手順 4 が失敗した場合は「範囲を選んだだけ」。**選択を戻して終わる。**
    @Test("書き込みが失敗したら選択だけ戻し、内容は変えない")
    func restoresSelectionWhenWriteFails() {
        let caretBefore = 2
        let world = ReplacementWorld(
            behavior: .rejected, userSelection: AXTextRange(location: caretBefore, length: 0))

        let result = world.replacer.replace(world.anchor, with: ReplacementWorld.refined)

        #expect(result.decline == .textWriteFailed)
        #expect(world.targetIsUntouched)
        #expect(world.contentWrites == 0)
        #expect(
            world.accessibility.calls.writtenRanges.last
                == AXTextRange(location: caretBefore, length: 0),
            "選択を戻していない"
        )
    }

    /// **secure input 中は差し替えも Undo も行わない**（`CompositeInserter.insert` と同じ扱い）。
    /// 整形を待つ間にパスワード欄へ移りうるので、**差し替えの直前にもう一度見る。**
    @Test("secure input 中は何も書き換えず、読み戻しもしない")
    func declinesWhileSecureInputIsEnabled() {
        let world = ReplacementWorld(secureInput: true)

        let result = world.replacer.replace(world.anchor, with: ReplacementWorld.refined)

        expectNothingWritten(world, result, .secureInput)
        #expect(
            world.accessibility.calls.readRanges.isEmpty,
            "パスワード入力中に読み戻しを行っている"
        )
    }

    /// **空文字への差し替えは「消すだけ」になる。** この設計が最も避けたい形なので、
    /// 手前で落とす。
    @Test("空文字への差し替えは行わない（消すだけになる）")
    func declinesEmptyReplacement() {
        let world = ReplacementWorld()
        expectNothingWritten(
            world, world.replacer.replace(world.anchor, with: ""), .emptyReplacement)
    }

    @Test("同じ文字列への差し替えは行わない")
    func declinesNoOpReplacement() {
        let world = ReplacementWorld()
        expectNothingWritten(
            world, world.replacer.replace(world.anchor, with: ReplacementWorld.raw),
            .nothingToChange)
    }

    /// 自プロセスの要素へ背景スレッドから書くと**永久にブロックする**（実測。§6.2）。
    @Test("自プロセスを指す錨では何も書き換えない")
    func declinesOwnProcess() {
        let world = ReplacementWorld(focusedProcess: getpid(), anchorProcess: getpid())
        expectNothingWritten(
            world, world.replacer.replace(world.anchor, with: ReplacementWorld.refined),
            .ownProcess)
    }

    /// 次の発話の挿入が始まったら、前の差し替えは撃たない（設計 opus §3.3）。
    /// **破棄しても生テキストは欄にある。**
    @Test("次の挿入が始まっていたら何も書き換えず、AX にも触らない")
    func declinesStaleAnchor() {
        let world = ReplacementWorld()
        world.epoch.advance()

        let result = world.replacer.replace(world.anchor, with: ReplacementWorld.refined)

        expectNothingWritten(world, result, .staleEpoch)
        #expect(world.accessibility.calls.readRanges.isEmpty, "失効した錨で AX を叩いている")
        #expect(world.accessibility.calls.writtenRanges.isEmpty)
    }
}

// MARK: - 事後検査（R-4 と喪失）

@Suite("差し替え: 事後検査")
struct TextReplacerVerificationTests {

    /// **R-4。AX が成功を返しながら何も入らない。** 発生は実機では未観測なので、
    /// 代役でしか再現できない。**成功として扱わないこと**がここの命題である。
    @Test("AX が成功を返しても何も入っていなければ成功として扱わない")
    func doesNotTreatSilentFailureAsSuccess() {
        let world = ReplacementWorld(behavior: .silentNoOp)

        let result = world.replacer.replace(world.anchor, with: ReplacementWorld.refined)

        #expect(!result.didReplace, "無言失敗を成功として扱っている")
        #expect(result.leftTargetUnchanged)
        if case .silentlyIgnored = result {} else { Issue.record("無言失敗として扱っていない") }
        #expect(world.targetIsUntouched, "何も起きていないはずが欄が変わっている")
        #expect(world.contentWrites == 1, "2 度目の書き込みを行っている")
        #expect(world.clipboard.left.isEmpty, "害の無い失敗でクリップボードを奪っている")
        #expect(world.announcer.announced.isEmpty)
        #expect(!world.replacer.isBlocked(ReplacementWorld.targetProcess), "無言失敗で締め出している")
    }

    /// 書き込みの後にキャレット位置が読めない／動かない相手でも、
    /// **「元の文字列がそのまま残っている」ことを確かめれば無言失敗と判る。**
    @Test("キャレットが動かない相手でも無言失敗を無言失敗として扱う")
    func detectsSilentFailureWhenCaretDoesNotMove() {
        let world = ReplacementWorld(behavior: .silentNoOp, caret: .unchanged)

        let result = world.replacer.replace(world.anchor, with: ReplacementWorld.refined)

        if case .silentlyIgnored = result {} else { Issue.record("無言失敗として扱っていない") }
        #expect(world.targetIsUntouched)
        #expect(world.contentWrites == 1)
    }

    /// **「消しただけ」——この設計における唯一の重い失敗。**
    /// 実機では未観測（V-25）だが、原理的には否定できない。
    @Test("消えるだけの相手では喪失として扱い、2 度目の書き込みをしない")
    func reportsLossWhenTextDisappears() {
        let world = ReplacementWorld(behavior: .erases)

        let result = world.replacer.replace(world.anchor, with: ReplacementWorld.refined)

        if case .lost = result {} else { Issue.record("喪失を検知していない") }
        #expect(!result.didReplace)
        #expect(!result.leftTargetUnchanged)
        #expect(world.contentWrites == 1, "二重挿入は入らないことより悪い（詳細設計書 §6.2）")
    }

    /// 喪失を検知したときの受けは 4 重（履歴・クリップボード・告知・以後の締め出し）。
    /// **履歴は呼び出し側が挿入直後に書いてある**ので、ここで見るのは残り 3 つ。
    @Test("喪失を検知したら、退避・告知・締め出しの 3 つを行う")
    func catchesLossWithThreeMeasures() {
        let world = ReplacementWorld(behavior: .replaces(with: "まったく別の内容になった"))

        let result = world.replacer.replace(world.anchor, with: ReplacementWorld.refined)

        if case .lost = result {} else { Issue.record("喪失を検知していない") }
        #expect(world.clipboard.left == [ReplacementWorld.refined], "退避していない")
        #expect(world.announcer.announced == [.textMayHaveBeenLost], "利用者へ告げていない")
        #expect(world.replacer.isBlocked(ReplacementWorld.targetProcess), "C-7 で締め出していない")
    }

    /// C-7。**一度でも喪失を出した相手には、以後試さない。**
    /// アプリ名の一覧を持たずに危険な相手を締め出せる。
    @Test("一度喪失を出したプロセスには、以後 AX にすら触らない")
    func neverTriesABlockedProcessAgain() {
        let world = ReplacementWorld(behavior: .erases)
        _ = world.replacer.replace(world.anchor, with: ReplacementWorld.refined)
        let writesAfterLoss = world.contentWrites
        let readsAfterLoss = world.accessibility.calls.readRanges.count

        let second = world.replacer.replace(world.anchor, with: ReplacementWorld.refined)

        #expect(second.decline == .blockedProcess)
        #expect(world.contentWrites == writesAfterLoss, "締め出した相手へ書き込んでいる")
        #expect(
            world.accessibility.calls.readRanges.count == readsAfterLoss,
            "締め出した相手を読んでいる"
        )
    }
}

// MARK: - NFR-V3 の最小例外（承認された 4 条件）

/// **利用者が明示的に承認した例外は「自分が直前に書き込んだ範囲の文字列だけを読む」までである。**
/// 承認の条件 4 つを、ここで検査に落として固定する。
///
/// | 条件 | 固定している検査 |
/// |---|---|
/// | 1. 範囲は自分が書いた場所に限る。前後 1 文字も広げない | `readsOnlyItsOwnRanges` / `readsOnlyItsOwnRangesWhenLost` |
/// | 2. 用途は比較のみ。真偽値 1 つに落とす | `rangeProbeCannotReturnText`（型で固定） |
/// | 3. 保持しない（履歴・計測・整形・ログのどこへも渡さない） | `readBackNeverEscapes` |
/// | 4. 不一致だった文字列の内容を一切見ない | `mismatchDecisionDoesNotDependOnContent` |
@Suite("NFR-V3 の最小例外の 4 条件")
struct ReplacementPrivacyTests {

    /// **条件 1。** 読んでよいのは (a) 挿入時に記録した錨の範囲と
    /// (b) いま書き込んだ範囲の 2 つだけである。
    @Test("読み戻す範囲は、自分が書いた 2 つの範囲のいずれかに限る")
    func readsOnlyItsOwnRanges() {
        let world = ReplacementWorld()

        _ = world.replacer.replace(world.anchor, with: ReplacementWorld.refined)

        let allowed: Set<AXTextRange> = [
            ReplacementWorld.anchorRange,
            AXTextRange(
                location: ReplacementWorld.anchorRange.location,
                length: ReplacementWorld.refined.count),
        ]
        #expect(!world.accessibility.calls.readRanges.isEmpty, "1 度も読んでいない（検査が空回り）")
        for range in world.accessibility.calls.readRanges {
            #expect(allowed.contains(range), "自分が書いていない範囲 \(range) を読んでいる")
        }
    }

    /// 喪失の経路でも同じ。**判らないからといって周りを読みにいかない。**
    @Test("喪失を疑うときも、自分が書いた範囲の外は読まない")
    func readsOnlyItsOwnRangesWhenLost() {
        let world = ReplacementWorld(behavior: .erases)

        _ = world.replacer.replace(world.anchor, with: ReplacementWorld.refined)

        let start = ReplacementWorld.anchorRange.location
        for range in world.accessibility.calls.readRanges {
            #expect(range.location == start, "範囲の開始を自分の場所からずらして読んでいる")
            #expect(
                range.length <= max(ReplacementWorld.raw.count, ReplacementWorld.refined.count),
                "自分が書いた長さを超えて読んでいる"
            )
        }
    }

    /// **条件 2 は型で固定する。** 読み取りの継ぎ目は `String` を返せない。
    /// `RangeMatch` は 3 値で、**一致しなかった内容を知る手段がそもそも無い。**
    @Test("読み戻しの継ぎ目は文字列を返せない（真偽値 1 つに落ちる）")
    func rangeProbeCannotReturnText() {
        let world = ReplacementWorld()
        let element = try! #require(world.accessibility.focusedElement())

        // 戻り値の型は `RangeMatch`。付随値を持たないので、内容は運べない。
        let match: RangeMatch = world.accessibility.matches(
            ReplacementWorld.raw, in: ReplacementWorld.anchorRange, of: element)
        #expect(match == .matched)

        let differed = world.accessibility.matches(
            "ちがう文字列", in: ReplacementWorld.anchorRange, of: element)
        #expect(differed == .differed)
        #expect(RangeMatch.differed.rawValue == "differed", "理由に内容が混ざっている")
    }

    /// **条件 3。** 読み戻した文字列が比較の外へ出ていないこと。
    /// 利用者が書いた目印の文字列が、結果・告知・クリップボード・錨のどこにも現れない。
    @Test("読み戻した利用者の文字は、結果のどこにも残らない")
    func readBackNeverEscapes() {
        let secret = "秘"
        let world = ReplacementWorld()
        world.field.userEdits(to: ReplacementWorld.editedContent(overwritingRawWith: secret))

        let result = world.replacer.replace(world.anchor, with: ReplacementWorld.refined)

        let exposed = [
            String(describing: result),
            String(describing: result.decline as Any),
            world.clipboard.left.joined(),
            world.announcer.announced.map(\.rawValue).joined(),
            String(describing: result.anchor?.text as Any),
            String(describing: result.anchor?.previousText as Any),
        ].joined(separator: " / ")

        #expect(!exposed.contains(secret), "読み戻した利用者の文字が外へ出ている: \(exposed)")
    }

    /// **条件 4。** 「違った」以上のことを判定に使っていない。
    /// **中身がまったく違っても、結果は同じ 1 つの理由へ落ちる。**
    @Test("不一致だったときの判定は、その内容に依存しない")
    func mismatchDecisionDoesNotDependOnContent() {
        // **同じ長さで中身だけが違う 2 つ。** 長さの違いで結果が割れる余地を消してある。
        let firstWorld = ReplacementWorld()
        firstWorld.field.userEdits(to: ReplacementWorld.editedContent(overwritingRawWith: "あ"))
        let first = firstWorld.replacer.replace(firstWorld.anchor, with: ReplacementWorld.refined)

        let secondWorld = ReplacementWorld()
        secondWorld.field.userEdits(
            to: ReplacementWorld.editedContent(overwritingRawWith: "パスワードらしき文字列"))
        let second = secondWorld.replacer.replace(
            secondWorld.anchor, with: ReplacementWorld.refined)

        #expect(first.decline == second.decline)
        #expect(first.decline == .sourceMismatch)
    }

    /// **錨をディスクへ持ち越さない**（設計 opus §2.2 の C-2）。
    /// `Codable` にした瞬間、`history.json` へ要素参照と範囲が書ける形になり、
    /// 別セッションから差し替えを撃てる型ができてしまう。
    @Test("差し替えの錨は永続化できない型である")
    func anchorIsNotPersistable() {
        #expect(
            !(ReplacementAnchor.self is any Codable.Type),
            "錨が Codable になっている（ディスクへ持ち越せてしまう）"
        )
        #expect(!(ReplacementAnchor.self is any Encodable.Type))
    }
}

// MARK: - 錨を取る経路（挿入器の契約）

@Suite("挿入時に差し替えの錨を取る")
struct ReplacementAnchorCaptureTests {

    private func inserter(
        _ fake: FakeAccessibility, epoch: InsertionEpoch = InsertionEpoch(),
        captures: Bool = true
    ) -> AccessibilityInserter {
        AccessibilityInserter(
            accessibility: fake, ownProcessIdentifier: getpid(), epoch: epoch,
            capturesReplacementAnchor: captures
        )
    }

    private func element() -> FakeAccessibility.Element {
        FakeAccessibility.Element(
            role: kAXTextAreaRole as String, isSelectedTextSettable: true,
            processIdentifier: ReplacementWorld.targetProcess, acceptsWrite: true
        )
    }

    @Test("挿入した場所を錨として持ち帰る")
    func capturesWhereItWrote() async {
        let field = FakeTextField(content: "前置き。")
        let fake = FakeAccessibility(focused: element(), field: field)

        let attempt = await inserter(fake).tryInsert("挿入した文字列")
        let anchor = try! #require(attempt.anchor)

        #expect(anchor.text == "挿入した文字列")
        #expect(anchor.range == AXTextRange(location: 4, length: 7))
        #expect(anchor.processIdentifier == ReplacementWorld.targetProcess)
        #expect(anchor.previousText == nil, "挿入しただけで Undo できる形になっている")
    }

    /// **長さを自分で数えない。** 範囲の単位は未実測（V-23）で 3 通りに割れうるので、
    /// 相手が返したキャレット位置の差だけを使う。前提が外れたら錨を作らない。
    @Test("キャレットが挿入文字列の直後に来ない相手では錨を作らない")
    func makesNoAnchorWhenCaretDoesNotLandAfterTheText() async {
        let field = FakeTextField(content: "前置き。", caret: .startOfRange)
        let fake = FakeAccessibility(focused: element(), field: field)

        let attempt = await inserter(fake).tryInsert("挿入した文字列")

        #expect(attempt.didInsert, "錨が取れないだけで挿入は成功している")
        #expect(attempt.anchor == nil)
    }

    @Test("読み戻せない相手では錨を作らない")
    func makesNoAnchorWhenReadBackIsUnavailable() async {
        let field = FakeTextField(content: "前置き。", respondsToStringForRange: false)
        let fake = FakeAccessibility(focused: element(), field: field)

        let attempt = await inserter(fake).tryInsert("挿入した文字列")

        #expect(attempt.didInsert)
        #expect(attempt.anchor == nil)
    }

    /// 錨を取らない設定では、**読み戻しを 1 度も行わない**（NFR-V3 の例外を使わない）。
    @Test("錨を取らない設定では読み戻しを一切行わない")
    func performsNoReadBackWhenAnchorCaptureIsOff() async {
        let field = FakeTextField(content: "前置き。")
        let fake = FakeAccessibility(focused: element(), field: field)

        let attempt = await inserter(fake, captures: false).tryInsert("挿入した文字列")

        #expect(attempt.didInsert)
        #expect(attempt.anchor == nil)
        #expect(fake.calls.readRanges.isEmpty, "錨を取らない設定なのに読み戻している")
    }

    @Test("錨には挿入時点の世代が刻まれる")
    func stampsCurrentEpoch() async {
        let epoch = InsertionEpoch()
        epoch.advance()
        let field = FakeTextField(content: "")
        let fake = FakeAccessibility(focused: element(), field: field)

        let attempt = await inserter(fake, epoch: epoch).tryInsert("挿入した文字列")

        #expect(attempt.anchor?.epoch == epoch.current)
    }
}

@Suite("CompositeInserter が返す錨")
struct CompositeInserterAnchorTests {

    private func element() -> FakeAccessibility.Element {
        FakeAccessibility.Element(
            role: kAXTextAreaRole as String, isSelectedTextSettable: true,
            processIdentifier: ReplacementWorld.targetProcess, acceptsWrite: true
        )
    }

    @Test("AX 経路で入ったときは錨を返す")
    func returnsAnchorForAccessibilityRoute() async {
        let epoch = InsertionEpoch()
        let field = FakeTextField(content: "")
        let composite = CompositeInserter(
            primary: AccessibilityInserter(
                accessibility: FakeAccessibility(focused: element(), field: field),
                ownProcessIdentifier: getpid(), epoch: epoch),
            fallback: StubInserter(canInsert: true, succeeds: true),
            lastResort: StubClipboard(), epoch: epoch, isSecureInputEnabled: { false }
        )

        let inserted = await composite.insertCapturingAnchor("挿入した文字列")

        #expect(inserted.outcome == .inserted(.ax))
        #expect(inserted.anchor?.text == "挿入した文字列")
    }

    /// **C-1。Pasteboard 経路の発話は差し替えられない。**
    /// 貼り付いたことすら確認できない（`CGEvent.post` は `Void`）ので、
    /// 二段目が錨を差し出しても受け取らない。
    @Test("Pasteboard 経路の錨は受け取らない")
    func dropsAnchorFromTheFallbackRoute() async {
        let offered = ReplacementAnchor(
            element: element(), processIdentifier: ReplacementWorld.targetProcess,
            range: AXTextRange(location: 0, length: 3), text: "テキスト", epoch: 1
        )
        let composite = CompositeInserter(
            primary: StubInserter(canInsert: false, succeeds: false),
            fallback: StubInserter(canInsert: true, succeeds: true, anchor: offered),
            lastResort: StubClipboard(), isSecureInputEnabled: { false }
        )

        let inserted = await composite.insertCapturingAnchor("テキスト")

        #expect(inserted.outcome == .inserted(.pasteboard))
        #expect(inserted.anchor == nil, "Pasteboard 経路の錨を受け取っている")
    }

    @Test("クリップボードへ残しただけのときは錨を返さない")
    func returnsNoAnchorForClipboardOnly() async {
        let composite = CompositeInserter(
            primary: StubInserter(canInsert: false, succeeds: false),
            fallback: StubInserter(canInsert: false, succeeds: false),
            lastResort: StubClipboard(), isSecureInputEnabled: { false }
        )

        let inserted = await composite.insertCapturingAnchor("テキスト")

        #expect(inserted.outcome == .inserted(.clipboardOnly))
        #expect(inserted.anchor == nil)
    }

    @Test("secure input で拒否したときは錨を返さない")
    func returnsNoAnchorWhenRefusing() async {
        let composite = CompositeInserter(
            primary: StubInserter(canInsert: true, succeeds: true),
            fallback: StubInserter(canInsert: true, succeeds: true),
            lastResort: StubClipboard(), isSecureInputEnabled: { true }
        )

        let inserted = await composite.insertCapturingAnchor("パスワードかもしれない発話")

        #expect(inserted.outcome == .refusedSecureInput)
        #expect(inserted.anchor == nil)
    }

    /// **次の発話の挿入が始まった時点で、前の差し替えは失効する。**
    /// 破棄しても生テキストは欄に残るので、縮退の向きは常に安全側である。
    @Test("次の挿入が始まると、前の錨は失効する")
    func invalidatesPendingAnchorOnNextInsertion() async {
        let epoch = InsertionEpoch()
        let field = FakeTextField(content: "")
        let composite = CompositeInserter(
            primary: AccessibilityInserter(
                accessibility: FakeAccessibility(focused: element(), field: field),
                ownProcessIdentifier: getpid(), epoch: epoch),
            fallback: StubInserter(canInsert: false, succeeds: false),
            lastResort: StubClipboard(), epoch: epoch, isSecureInputEnabled: { false }
        )

        let first = await composite.insertCapturingAnchor("一回目")
        let firstAnchor = try! #require(first.anchor)
        _ = await composite.insertCapturingAnchor("二回目")

        #expect(firstAnchor.epoch != epoch.current, "前の錨が失効していない")
    }

    /// 拒否されても世代は進む。**失効の縮退先は「差し替えない」＝安全側。**
    @Test("secure input で拒否した場合も世代は進む")
    func advancesEpochEvenWhenRefusing() async {
        let epoch = InsertionEpoch()
        let composite = CompositeInserter(
            primary: StubInserter(canInsert: true, succeeds: true),
            fallback: StubInserter(canInsert: true, succeeds: true),
            lastResort: StubClipboard(), epoch: epoch, isSecureInputEnabled: { true }
        )
        let before = epoch.current

        _ = await composite.insertCapturingAnchor("パスワードかもしれない発話")

        #expect(epoch.current != before)
    }

    /// **`insert(_:)` は `insertCapturingAnchor(_:)` の薄い包みであること。**
    /// 2 つの経路を別々に実装すると、片方だけ直したときに挙動が割れる。
    @Test("錨を使わない呼び出しでも経路の判定は同じ")
    func plainInsertMatchesAnchoringInsert() async {
        for (canAX, expected) in [
            (true, InsertionOutcome.inserted(.ax)), (false, .inserted(.pasteboard)),
        ] {
            let composite = CompositeInserter(
                primary: StubInserter(canInsert: canAX, succeeds: true),
                fallback: StubInserter(canInsert: true, succeeds: true),
                lastResort: StubClipboard(), isSecureInputEnabled: { false }
            )
            #expect(await composite.insert("テキスト") == expected)
        }
    }
}

// MARK: - Undo の候補（carry-ins 項目 16）

/// **挿入していない発話へ Undo を撃つと、別の何かを消す。**
/// `refinedText != nil` と 10 秒窓だけでは `.clipboardOnly` が素通りする。
@Suite("Undo の候補は挿入経路を見る")
struct AutomaticUndoCandidateTests {

    private func entry(_ method: InsertionMethod, refined: String? = "整形後") -> HistoryEntry {
        HistoryEntry(
            rawText: "生テキスト", refinedText: refined, localeIdentifier: "ja-JP",
            insertionMethod: method
        )
    }

    @Test("AX 経路で整形して挿入した発話だけが候補になる")
    func onlyAccessibilityRouteIsCandidate() {
        #expect(entry(.ax).isAutomaticUndoCandidate)
    }

    /// **これが carry-ins 項目 16 そのもの。** クリップボードへ残しただけの発話は
    /// 挿入されていないので、戻すべき挿入が存在しない。
    @Test("クリップボードへ残しただけの発話は候補にしない")
    func clipboardOnlyIsNotCandidate() {
        #expect(!entry(.clipboardOnly).isAutomaticUndoCandidate, "挿入していない発話を戻そうとしている")
    }

    /// 貼り付いたことすら確認できない（`CGEvent.post` は `Void`）。範囲も無い。
    @Test("Pasteboard 経路の発話は自動 Undo の候補にしない")
    func pasteboardIsNotCandidate() {
        #expect(!entry(.pasteboard).isAutomaticUndoCandidate)
    }

    @Test("中断された発話は候補にしない")
    func cancelledIsNotCandidate() {
        #expect(!entry(.notInserted, refined: nil).isAutomaticUndoCandidate)
        // 万一 refinedText が付いていても、挿入経路を通っていない事実は変わらない。
        #expect(!entry(.notInserted).isAutomaticUndoCandidate)
    }

    @Test("整形していない発話は戻す先が無いので候補にしない")
    func unrefinedIsNotCandidate() {
        #expect(!entry(.ax, refined: nil).isAutomaticUndoCandidate)
    }
}
