import Foundation
import Synchronization

/// AX のテキスト範囲。**位置と長さの整数 2 つだけで、文字を一切含まない。**
///
/// NFR-V3（周辺テキストを読み取らない）に触れないのはこのためである
/// （設計 opus §2.3 の表）。
///
/// - Important: **単位は未実測である。** UTF-16 か、グラフェムクラスタか、
///   `unicodeScalars` かは相手のアプリに依存しうる（`👨‍👩‍👧‍👦` は
///   `count 1 / utf16 11 / unicodeScalars 7` に割れる）。**この型を使う側は
///   長さを自分で数えてはならない。** `AccessibilityRangeProbing.selectedRange(of:)`
///   が返した位置の差だけを長さとして使い、**読み戻して一致したときだけ書く**
///   （`TextReplacer`）。単位が想定と違っても「中止」に倒れる。検証項目 V-23。
public struct AXTextRange: Sendable, Equatable, Hashable {
    public let location: Int
    public let length: Int

    public init(location: Int, length: Int) {
        self.location = location
        self.length = length
    }

    /// 範囲の終端（この位置は含まない）。
    public var end: Int { location + length }
}

/// 範囲を読み戻した結果。**読み取った文字列そのものは決してここに入らない。**
///
/// 承認された NFR-V3 の最小例外の条件 2（用途は比較のみ。真偽値 1 つに落とす）と
/// 条件 4（不一致だった文字列の内容を一切見ない）を、**型で守るためにこの形にしてある。**
/// `AccessibilityRangeProbing.matches(_:in:of:)` が `String?` を返す形にすると、
/// 読み戻した利用者の文字が呼び出し側へ出てしまい、そこから先は規律でしか守れない。
public enum RangeMatch: String, Sendable, Equatable {
    /// 期待した文字列と完全に一致した。
    case matched
    /// 一致しなかった。**「違った」以上のことは判らない**（意図的にそうしてある）。
    case differed
    /// 読めなかった（`AXStringForRange` に応えない相手・範囲外など）。
    case unreadable
}

/// 挿入の通し番号。**保留中の差し替えを失効させるための世代である。**
///
/// 次の発話の挿入が始まった時点で、前の発話の差し替えは撃ってはならない
/// （設計 opus §3.3「直列性と後始末」）。破棄しても生テキストは欄に残るので、
/// **いつ破棄しても「何も書き換えていない」状態で終わる。**
public final class InsertionEpoch: Sendable {
    private let value = Atomic<UInt64>(1)

    public init() {}

    /// 現在の世代。
    public var current: UInt64 { value.load(ordering: .relaxed) }

    /// 世代を進める。**これ以前に発行した錨はすべて失効する。**
    @discardableResult
    public func advance() -> UInt64 {
        value.add(1, ordering: .relaxed).newValue
    }
}

/// 「後から差し替えられる場所」の錨。
///
/// **ディスクへ持ち越さない（`Codable` にしない）。** 別プロセス・別セッションから
/// 差し替えを撃つと、そこはもう自分が書いた場所ではない（設計 opus §2.2 の C-2）。
/// 要素参照はプロセス内のメモリでしか意味を持たない。
///
/// - Note: `HistoryEntry` に持たせてはならない。履歴は `history.json` へ落ちる。
public struct ReplacementAnchor: Sendable {
    /// 書き込んだ相手の要素。**プロセス内のメモリのみ。**
    public let element: any FocusedElement
    /// 書き込んだ相手のプロセス。
    public let processIdentifier: pid_t
    /// **自分が書いた場所。** 読み戻してよいのはここだけである。
    public let range: AXTextRange
    /// その場所へ自分が書いた文字列。事前検査はこれとの一致だけを見る。
    public let text: String
    /// **その場所に、それより前に自分が書いていた文字列。**
    ///
    /// 差し替えが成功したときに `text` の直前の値がここへ入る。
    /// **FR-7（Undo）はこれを `text` の位置へ書き戻すだけである**
    /// （`TextReplacer.undo(_:)`）。差し替えと Undo が同じ原始操作になるのはこのため。
    public let previousText: String?
    /// この錨を発行した世代。次の挿入が始まると失効する。
    public let epoch: UInt64

    public init(
        element: any FocusedElement,
        processIdentifier: pid_t,
        range: AXTextRange,
        text: String,
        previousText: String? = nil,
        epoch: UInt64
    ) {
        self.element = element
        self.processIdentifier = processIdentifier
        self.range = range
        self.text = text
        self.previousText = previousText
        self.epoch = epoch
    }
}

/// 一段の挿入器が返す結果。
///
/// **`Bool` から変えた理由。** 差し替えには「どのプロセスの・どの要素の・どの範囲へ
/// 書いたか」が要る（設計 codex §2.2 の表: `PrimaryInserting.tryInsert` は `Bool` しか
/// 返さず、配送確認・pid・範囲・後から置換できるかを表せない）。
public enum InsertionAttempt: Sendable {
    /// 入らなかった。次の段へ落とす。
    case failed
    /// 入った。**錨が取れた場合だけ後から差し替えられる。**
    ///
    /// `anchor` が nil でも挿入そのものは成功している。差し替えを諦めるだけで、
    /// 生テキストは欄にある（＝現行の正常系）。
    case inserted(anchor: ReplacementAnchor?)

    /// テキストが入ったか。
    public var didInsert: Bool {
        if case .inserted = self { return true }
        return false
    }

    /// 差し替えの錨。取れなかったときと失敗したときは nil。
    public var anchor: ReplacementAnchor? {
        if case .inserted(let anchor) = self { return anchor }
        return nil
    }
}

/// 合成器が返す、挿入の結果と差し替えの錨。
///
/// - Important: **`anchor` が nil でも発話は失われていない。** `outcome` が
///   `.inserted(...)` なら、テキストは欄かクリップボードにある。nil が意味するのは
///   「後から差し替えられない」だけである。
public struct AnchoredInsertion: Sendable {
    public let outcome: InsertionOutcome
    /// 差し替えの錨。**`.ax` 経路で、かつ範囲を確かめられた場合のみ非 nil**
    /// （設計 opus §2.2 の C-1）。
    public let anchor: ReplacementAnchor?

    public init(outcome: InsertionOutcome, anchor: ReplacementAnchor?) {
        self.outcome = outcome
        self.anchor = anchor
    }
}
