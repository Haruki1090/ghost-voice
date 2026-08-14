import Foundation

/// テキスト挿入に実際に使われた経路。履歴に記録し、どのアプリでどの経路が
/// 使われたかの実地データとする（検証項目 V-3）。
public enum InsertionMethod: String, Codable, Sendable {
    /// Accessibility API で直接挿入した
    case ax
    /// クリップボード経由で ⌘V を送出した
    case pasteboard
    /// 挿入に失敗し、クリップボードへ残すのみに留めた
    case clipboardOnly
    /// 挿入していない。**ESC で中断された発話**がこれになる。
    ///
    /// 基本設計書 §4 は「中断時、録音済み内容は破棄せず履歴に残す」と定めている。
    /// 中断された発話は一度も挿入経路を通っていないので、`.ax` / `.pasteboard` /
    /// `.clipboardOnly` のどれで記録しても事実に反する。特に `.clipboardOnly` は
    /// 「クリップボードに残っている」という嘘になり、Task 8 が潰した
    /// 「成功と記録されるのにテキストがどこにも無い」と同じ形の欠陥になる。
    ///
    /// 整形も経ていないため `refinedText` は nil であり、`undoCandidate` の
    /// 対象にはならない（戻すべき挿入が存在しない）。効くのは FR-9 の再挿入だけである。
    case notInserted
}

/// 挿入を試みた結果。
///
/// **`InsertionMethod` を直に返さないのは、履歴へ記録してはならない結果があるため。**
/// `HistoryEntry.insertionMethod` は `InsertionMethod` を必須で要求するので、
/// 記録できない結果を `InsertionMethod` の一ケースとして表すと、
/// **記録してはならないものを記録できてしまう**（型として表現可能になる）。
/// 分けておけば、履歴を作るには `recordableMethod` を開く一手間が要る。
public enum InsertionOutcome: Sendable, Equatable {
    /// 挿入を試み、この経路で決着した。**履歴に記録してよい。**
    case inserted(InsertionMethod)

    /// secure input が有効だったため、**どの経路も試さずに拒否した。**
    ///
    /// クリップボードにも残していない。**履歴に記録してはならない。**
    /// 理由は `CompositeInserter.insert(_:)` を参照。
    case refusedSecureInput

    /// 履歴に記録してよい経路。拒否のときは nil。
    ///
    /// 記録側はこれを開いてから `HistoryEntry` を作ること。
    /// ```swift
    /// guard let method = outcome.recordableMethod else { return }  // 拒否は記録しない
    /// ```
    public var recordableMethod: InsertionMethod? {
        switch self {
        case .inserted(let method): method
        case .refusedSecureInput: nil
        }
    }
}
