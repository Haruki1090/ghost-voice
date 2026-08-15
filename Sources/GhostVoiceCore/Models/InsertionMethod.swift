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
    /// 挿入していない。**ESC で中断された発話**と、
    /// **どの経路でも挿入できずクリップボードへも残せなかった発話**がこれになる。
    ///
    /// 基本設計書 §4 は「中断時、録音済み内容は破棄せず履歴に残す」と定めている。
    /// 中断された発話は一度も挿入経路を通っていないので、`.ax` / `.pasteboard` /
    /// `.clipboardOnly` のどれで記録しても事実に反する。特に `.clipboardOnly` は
    /// 「クリップボードに残っている」という嘘になり、Task 8 が潰した
    /// 「成功と記録されるのにテキストがどこにも無い」と同じ形の欠陥になる。
    ///
    /// 整形も経ていないため `refinedText` は nil であり、`undoCandidate` の
    /// 対象にはならない（戻すべき挿入が存在しない）。効くのは FR-9 の再挿入だけである。
    ///
    /// **差し替え（FR-5(a) / FR-7）の観点でも同じである。** 差し替えハンドルは
    /// `.ax` 経路でしか作られないので、この経路の発話を戻そうとする道が構造的に無い
    /// （要件定義書 §2.8.6 / 詳細設計書 §8.3）。
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

    /// **どの経路でも挿入できず、最後の砦（クリップボードへの残置）も失敗した。**
    ///
    /// `.inserted(.clipboardOnly)` と混ぜてはならない。あちらは
    /// 「クリップボードへ残した」という主張であり、利用者は ⌘V で取り出せる。
    /// こちらは**テキストが欄にもクリップボードにも無い**——
    /// **履歴が最後の写しである**（したがって `recordableMethod` は nil ではない）。
    ///
    /// 以前はこのケースが無く、`CompositeInserter` が
    /// `lastResort.leave(text)` の戻り値を捨てて `.inserted(.clipboardOnly)` を
    /// 返していた。**置けていなくても「⌘V で貼れます」と告げ、
    /// 履歴書き込みも失敗すると嘘を言ったうえで発話が完全に消えた**（最終レビュー A-2）。
    case failedEverywhere

    /// 履歴に記録してよい経路。**secure input の拒否のときだけ nil。**
    ///
    /// 記録側はこれを開いてから `HistoryEntry` を作ること。
    /// ```swift
    /// guard let method = outcome.recordableMethod else { return }  // 拒否は記録しない
    /// ```
    ///
    /// - Important: `.failedEverywhere` は nil ではない。**テキストがどこにも無いからこそ、
    ///   履歴に残さなければ発話が完全に消える。**
    public var recordableMethod: InsertionMethod? {
        switch self {
        case .inserted(let method): method
        case .failedEverywhere: .notInserted
        case .refusedSecureInput: nil
        }
    }

    /// **テキストが利用者の手元（挿入先の欄かクリップボード）にあるか。**
    ///
    /// 履歴へ書けなかったときの文言を分けるために要る——
    /// `SessionFailure.historyUnavailable(insertedElsewhere:)` は
    /// 「失うのは履歴と Undo だけ」と「発話そのものが失われた」を区別しており、
    /// **利用者にとって意味がまったく違う。**
    public var leftTextWithUser: Bool {
        switch self {
        case .inserted: true
        case .failedEverywhere, .refusedSecureInput: false
        }
    }
}
