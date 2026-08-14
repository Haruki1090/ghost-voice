import ApplicationServices
import Carbon.HIToolbox
import Foundation
import Synchronization

/// 差し替えを行わなかった理由。**どれも「対象アプリの欄を 1 文字も変えていない」を意味する。**
///
/// - Important: **理由に利用者の文字は決して入らない。** 事前検査が一致しなかった場合
///   （`.sourceMismatch`）にそこへ何が書かれていたかは、この型からも他のどこからも
///   知れない（NFR-V3 の最小例外の条件 4）。
public enum ReplacementDecline: String, Sendable, Equatable {
    /// C-7。過去に喪失の疑いを出した相手なので、以後試さない。
    case blockedProcess
    /// 次の発話の挿入が始まっており、この錨は失効している。
    case staleEpoch
    /// 錨が自プロセスを指している（自分へ書くと永久にブロックする）。
    case ownProcess
    /// 差し替える内容が現在の内容と同じ。書く必要が無い。
    case nothingToChange
    /// 空文字への差し替えは行わない。**「消すだけ」になる。**
    case emptyReplacement
    /// secure input が有効。**唯一「発話を残さない」ことを正とする分岐**（基本設計書 §7）。
    case secureInput
    /// C-4。フォーカスが別の欄（または不明）へ移った。
    case focusChanged
    /// C-3。最前面が別のアプリへ移った。
    case processChanged
    /// C-5。選択範囲／選択テキストが書き込み可能でない。
    case rangeNotSettable
    /// C-6。**自分が書いた場所の内容が変わっている**（利用者の編集・カーソル移動・
    /// アプリ側の変換のいずれか。区別はしない）。
    case sourceMismatch
    /// C-6。読み戻せない（`AXStringForRange` に応えない相手など）。
    case sourceUnreadable
    /// 手順 3。選択範囲の設定が失敗した。
    case rangeWriteFailed
    /// 手順 4。選択テキストの書き込みが失敗した。**選択だけ戻してある。**
    case textWriteFailed
    /// Undo する先が無い（まだ一度も差し替えていない錨）。
    case nothingToUndo
}

/// 差し替えの結果。
///
/// **`.replaced` 以外はすべて「対象アプリの欄の内容を変えていない」。**
/// `.lost` だけが例外で、そこは「変えたかどうかが判らない」（詳細は各ケース）。
public enum ReplacementResult: Sendable {
    /// 差し替えて、読み戻しで一致まで確かめた。**返る錨は新しい範囲を指す。**
    /// `anchor.previousText` に差し替え前の文字列が入っているので、
    /// これをそのまま `undo(_:)` へ渡せる。
    case replaced(ReplacementAnchor)

    /// 成立条件が欠けたので**何も書き換えなかった。**
    ///
    /// **発話は挿入済みの生テキストとして欄にあり、整形結果は履歴にある。**
    /// これは現行実装の正常系そのものである。
    case declined(ReplacementDecline)

    /// AX が成功を返したが、事後検査で**元の文字列がそのまま残っていた**（R-4 の無言失敗）。
    ///
    /// **成功として扱わない。** ただし何も起きていないので害も無い。
    /// 欄には差し替え前の文字列がある。
    case silentlyIgnored

    /// 事後検査が「新しい文字列」でも「元の文字列」でもなかった。**喪失の疑い。**
    ///
    /// **2 度目の書き込みは行わない**（二重挿入は入らないことより悪い。詳細設計書 §6.2）。
    /// 代わりに 4 重で受ける:
    /// 1. 履歴（呼び出し側が挿入直後に書いてある。実測 0.44 ms）
    /// 2. **差し替えようとした文字列をクリップボードへ残す**
    /// 3. 利用者へ告げる（`ReplacementAnnouncing`）
    /// 4. **以後そのアプリでは差し替えを試さない**（C-7）
    case lost

    /// **対象アプリの欄の内容を書き換えたか。**
    ///
    /// `.declined` と `.silentlyIgnored` は必ず false。`.lost` は「判らない」ので
    /// ここでは true 側に数えない——判定に使うのは「安全に戻ってきたか」であり、
    /// `.lost` はどちらでもないためである（`isSafe` を見ること）。
    public var didReplace: Bool {
        if case .replaced = self { return true }
        return false
    }

    /// **欄が差し替え前の状態のままであることが確かめられたか。**
    ///
    /// `.declined` と `.silentlyIgnored` が true。`.replaced` は成功、
    /// `.lost` だけが「確かめられていない」。
    public var leftTargetUnchanged: Bool {
        switch self {
        case .declined, .silentlyIgnored: return true
        case .replaced, .lost: return false
        }
    }

    /// 中止した理由。中止でなければ nil。
    public var decline: ReplacementDecline? {
        if case .declined(let reason) = self { return reason }
        return nil
    }

    /// 差し替え後の錨。成功時のみ。
    public var anchor: ReplacementAnchor? {
        if case .replaced(let anchor) = self { return anchor }
        return nil
    }
}

/// 利用者へ告げること。**HUD の実装は別トラックが行う。ここは口だけを用意する。**
///
/// - Important: **文言も本文も持たせない。** 通知に発話やその一部を載せると、
///   ログや通知センターへ発話が漏れる経路が生まれる。
public enum ReplacementNotice: String, Sendable, Equatable {
    /// **差し替えの途中で、欄の内容が判らなくなった。**
    /// 差し替えようとした文字列はクリップボードにある。
    case textMayHaveBeenLost
}

/// 告げる先。
public protocol ReplacementAnnouncing: Sendable {
    func announce(_ notice: ReplacementNotice)
}

/// 何もしない告知先。配線されるまでの既定。
public struct SilentAnnouncer: ReplacementAnnouncing {
    public init() {}
    public func announce(_ notice: ReplacementNotice) {}
}

/// **挿入済みのテキストを、後から別の文字列へ差し替える。**
///
/// この 1 つの操作の上に、必須要件が 2 つ載っている。
///
/// - **FR-5(a)**: 生テキストを先に挿入して NFR-P6a（1 秒）を守り、整形が返ったら
///   `replace(_:with:)` で整形結果へ差し替える。
/// - **FR-7**: 直近の挿入を整形前の生テキストへ戻す。**同じ操作を逆向きに使うだけ**で、
///   `undo(_:)` は `replace(_:with: anchor.previousText)` の薄い包みである。
///
/// ## 使い方（配線担当へ）
///
/// ```swift
/// let stack = CompositeInserter.systemStack(announcer: myHUD)
///
/// // 1. 生テキストを挿入し、錨を受け取る。錨が nil でも挿入は成功している。
/// let inserted = await stack.inserter.insertCapturingAnchor(rawText)
/// guard let method = inserted.outcome.recordableMethod else { return }  // secure input は記録しない
/// try history.append(HistoryEntry(rawText: rawText, refinedText: nil, ..., insertionMethod: method))
///
/// // 2. 整形が返ってから差し替える。**ここで phase を .idle にしてよい**
/// //    （差し替えは「忙しい」に数えない。捨てても生テキストは欄にある）。
/// guard let anchor = inserted.anchor else { return }   // 差し替えられない相手。生テキストのまま
/// let result = stack.replacer.replace(anchor, with: refinedText)
///
/// // 3. Undo（⌃⌘Z）。**門はこの錨であって履歴ではない。**
/// if let replaced = result.anchor {
///     let undone = stack.replacer.undo(replaced)     // 整形前の生テキストへ戻る
/// }
/// ```
///
/// ## この呼び出しが失敗しても発話は失われない
///
/// **`replace(_:with:)` は、成立条件が 1 つでも欠けたら「何も書き換えない」で返る。**
/// 縮退先は常に「挿入済みの生テキストが欄にある」＝**現行実装の正常系そのもの**である
/// （`ReplacementResult.leftTargetUnchanged`）。
///
/// **「消してから書く」形は存在しない。** ⌫ や ⌘Z の送出（`CGEvent.post` は `Void` を
/// 返し、届いたか判らない）を使えば、消えたが書けていない窓で発話を失う。
/// **AX の範囲上書きだけが、消すことと書くことを 1 回の呼び出しに閉じ込められる**
/// （統括の裁定 / 設計 opus §2.1）。
///
/// 唯一「判らない」に落ちるのは事後検査が喪失を示した場合（`.lost`）で、そこは
/// 履歴・クリップボード・告知・C-7 の 4 重で受ける。
///
/// - Important: **`swift test` から実機のアプリへ書き込んではならない。**
///   全経路は `FakeTextField` で決定的に駆動できる（`TextReplacerTests`）。
public final class TextReplacer: Sendable {

    private let accessibility: any ReplacementCapableAccessibility
    private let clipboard: any ClipboardLeaving
    private let announcer: any ReplacementAnnouncing
    private let epoch: InsertionEpoch
    private let ownProcessIdentifier: pid_t
    private let isSecureInputEnabled: @Sendable () -> Bool
    /// C-7。**一度でも喪失の疑いを出した相手**。アプリ名の一覧を持たずに危険な相手を締め出す。
    private let blocked = Mutex<Set<pid_t>>([])

    /// - Parameters:
    ///   - epoch: 挿入の世代。**挿入器と同じものを渡すこと。**
    ///   - clipboard: 喪失を検知したときの退避先。**挿入器と同じクリップボードを渡すこと**
    ///     （別の `NSPasteboard` を掴ませると、退避したテキストが誰にも見えない場所へ行く）。
    ///   - announcer: 利用者へ告げる口。HUD は別トラック。
    public init(
        accessibility: any ReplacementCapableAccessibility = SystemAccessibility(),
        clipboard: any ClipboardLeaving,
        announcer: any ReplacementAnnouncing = SilentAnnouncer(),
        epoch: InsertionEpoch,
        ownProcessIdentifier: pid_t = getpid(),
        isSecureInputEnabled: @escaping @Sendable () -> Bool = { IsSecureEventInputEnabled() }
    ) {
        self.accessibility = accessibility
        self.clipboard = clipboard
        self.announcer = announcer
        self.epoch = epoch
        self.ownProcessIdentifier = ownProcessIdentifier
        self.isSecureInputEnabled = isSecureInputEnabled
    }

    /// C-7 で締め出した相手か。
    public func isBlocked(_ processIdentifier: pid_t) -> Bool {
        blocked.withLock { $0.contains(processIdentifier) }
    }

    /// **FR-7。直近の差し替えを 1 つ戻す。**
    ///
    /// 差し替えと同じ原始操作を逆向きに使うだけである。**戻せるのは
    /// `replace(_:with:)` が返した錨だけ**で、挿入しただけの錨（`previousText == nil`）は
    /// `.declined(.nothingToUndo)` になる。**挿入していない発話へ Undo を撃つ経路は、
    /// 型として存在しない**——錨は `.ax` 経路の挿入でしか作られないためである
    /// （carry-ins 項目 16 が構造的に消える）。
    public func undo(_ anchor: ReplacementAnchor) -> ReplacementResult {
        guard let previous = anchor.previousText else { return .declined(.nothingToUndo) }
        return replace(anchor, with: previous)
    }

    /// **挿入済みのテキストを差し替える。5 手 + 後始末**（設計 opus §2.5）。
    ///
    /// ```
    /// 1. 事前読み : 利用者の現在の選択範囲（整数 2 つ）
    /// 2. 事前検査 : 自分が書いた範囲の文字列が、自分が書いたものと一致するか
    /// 3. 範囲設定 : kAXSelectedTextRange ← 記録した範囲
    /// 4. 上書き   : kAXSelectedText ← 新しい文字列（**内容を変えるのはこの 1 回だけ**）
    /// 5. 事後検査 : 新しい範囲を読み戻して一致するか
    /// 6. 後始末   : 手順 1 の選択を、長さの差だけ補正して書き戻す
    /// ```
    ///
    /// **成立条件は安い順に判定する**（`AccessibilityInserter.canInsert()` に倣う）。
    /// AX の往復を 1 度も行わずに落とせる条件を先に置いてある。
    ///
    /// - Returns: **`.replaced` 以外は「欄を書き換えていない」。**
    ///   `.lost` だけが「判らない」で、そこは退避・告知・締め出しを済ませてある。
    public func replace(_ anchor: ReplacementAnchor, with replacement: String)
        -> ReplacementResult
    {
        // --- ここから: AX の往復を伴わない判定（安い順） ---

        // C-7。喪失を出した相手には二度と触らない。**AX を 1 度も叩かない。**
        guard !isBlocked(anchor.processIdentifier) else { return .declined(.blockedProcess) }
        // 次の発話の挿入が始まっていたら撃たない。破棄しても生テキストは欄にある。
        guard anchor.epoch == epoch.current else { return .declined(.staleEpoch) }
        // 自プロセスへの書き込みは背景スレッドから永久にブロックする（実測。§6.2）。
        guard anchor.processIdentifier != ownProcessIdentifier else {
            return .declined(.ownProcess)
        }
        // **空文字への差し替えは行わない。** 通れば「消すだけ」になり、
        // この設計が最も避けたい形（発話が欄から消える）を自分で作ることになる。
        guard !replacement.isEmpty else { return .declined(.emptyReplacement) }
        guard replacement != anchor.text else { return .declined(.nothingToChange) }

        // secure input（実測 0.000 ms）。**整形を待つ間にパスワード欄へ移りうるので、
        // 挿入時に見たことは根拠にならない。差し替えの直前にもう一度見る。**
        // 中止しても生テキストは既に欄にある（挿入時点では secure input ではなかった
        // ので、これは新しい漏れではない）。
        guard !isSecureInputEnabled() else { return .declined(.secureInput) }

        // --- ここから: AX の読み取り（0.1〜5.5 ms / 往復。書き込みはまだ 1 度もしない）---

        guard let current = accessibility.focusedElement() else {
            return .declined(.focusChanged)
        }
        // C-3。別アプリへ移ってから撃たない。
        guard accessibility.processIdentifier(of: current) == anchor.processIdentifier else {
            return .declined(.processChanged)
        }
        // C-4。同じアプリの別の入力欄へ書かない。
        guard accessibility.isSameElement(current, anchor.element) else {
            return .declined(.focusChanged)
        }
        // C-5。範囲を選べない相手に書きにいかない。
        guard accessibility.isSelectedTextRangeSettable(current),
              accessibility.isSelectedTextSettable(current)
        else { return .declined(.rangeNotSettable) }

        // 手順 2（C-6。**この設計の要**）。
        // 位置の算術を信じず、**読み戻して一致したときだけ書く。** 一致しなければ
        // 理由を問わず中止する——利用者が編集したのか、カーソルがずれたのか、
        // アプリが変換したのかは区別しないし、**区別するために内容を見ることもしない。**
        switch accessibility.matches(anchor.text, in: anchor.range, of: current) {
        case .matched: break
        case .differed: return .declined(.sourceMismatch)
        case .unreadable: return .declined(.sourceUnreadable)
        }

        // 手順 1。利用者の現在の選択（整数 2 つ。文字は読まない）。後始末で戻す。
        let userSelection = accessibility.selectedRange(of: current)

        // 手順 3。**ここから書き込みが始まる。ただし内容はまだ変わらない。**
        guard accessibility.setSelectedRange(anchor.range, on: current) else {
            return .declined(.rangeWriteFailed)
        }

        // 手順 4。**欄の内容を変えるのはこの 1 回だけである。**
        guard accessibility.setSelectedText(replacement, on: current) else {
            // 範囲を選んだだけ。選択を戻して終わる（内容は変わっていない）。
            restore(userSelection, on: current, shiftedBy: 0, from: anchor.range)
            return .declined(.textWriteFailed)
        }

        return verify(anchor: anchor, replacement: replacement, on: current,
                      userSelection: userSelection)
    }

    /// 手順 5（事後検査）と手順 6（後始末）。
    ///
    /// **読み戻す範囲は 2 つだけで、どちらも「自分が書いた場所」である。**
    /// (a) いま書き込んだ範囲、(b) 挿入時に記録した錨の範囲。
    /// **これより前・これより後ろは 1 文字も読まない**（NFR-V3 の条件 1）。
    private func verify(
        anchor: ReplacementAnchor, replacement: String, on element: any FocusedElement,
        userSelection: AXTextRange?
    ) -> ReplacementResult {
        // 新しい長さも自分で数えない。相手が返したキャレット位置の差を使う
        // （範囲の単位が未実測のため。`AXTextRange` の注記）。
        let newRange = accessibility.selectedRange(of: element).flatMap { after -> AXTextRange? in
            guard after.length == 0, after.location >= anchor.range.location else { return nil }
            return AXTextRange(
                location: anchor.range.location, length: after.location - anchor.range.location)
        }

        if let newRange,
           accessibility.matches(replacement, in: newRange, of: element) == .matched {
            restore(userSelection, on: element,
                    shiftedBy: newRange.length - anchor.range.length, from: anchor.range)
            return .replaced(
                ReplacementAnchor(
                    element: anchor.element, processIdentifier: anchor.processIdentifier,
                    range: newRange, text: replacement, previousText: anchor.text,
                    epoch: anchor.epoch
                ))
        }

        // 新しい文字列ではなかった。**元の文字列がそのまま残っているか**を見る。
        if accessibility.matches(anchor.text, in: anchor.range, of: element) == .matched {
            // R-4 の無言失敗。**成功として扱わない。** 何も起きていないので害は無い。
            restore(userSelection, on: element, shiftedBy: 0, from: anchor.range)
            return .silentlyIgnored
        }

        // どちらでもない。**喪失の疑い。2 度目の書き込みはしない。**
        // 二重挿入は入らないことより悪い（詳細設計書 §6.2）。選択も戻さない——
        // 欄がどうなっているか判らない状態で、これ以上触るほうが危ない。
        clipboard.leave(replacement)
        announcer.announce(.textMayHaveBeenLost)
        blocked.withLock { _ = $0.insert(anchor.processIdentifier) }
        return .lost
    }

    /// 手順 6。利用者の選択を、長さの差だけ補正して書き戻す。
    ///
    /// **失敗しても何もしない。** これは後始末であって、発話の在り処には関わらない。
    private func restore(
        _ selection: AXTextRange?, on element: any FocusedElement, shiftedBy delta: Int,
        from replaced: AXTextRange
    ) {
        guard let selection else { return }
        let adjusted: AXTextRange
        if selection.end <= replaced.location {
            // 差し替えた場所より前。動かない。
            adjusted = selection
        } else if selection.location >= replaced.end {
            // 差し替えた場所より後ろ。長さの差だけずれる。
            adjusted = AXTextRange(location: selection.location + delta, length: selection.length)
        } else {
            // 差し替えた場所に重なっていた。**安全に補正できない**ので、
            // 新しい文字列の直後へキャレットを置く。
            adjusted = AXTextRange(location: replaced.location + replaced.length + delta, length: 0)
        }
        _ = accessibility.setSelectedRange(adjusted, on: element)
    }
}
