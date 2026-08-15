import Foundation

public struct HistoryEntry: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let timestamp: Date
    /// 整形前の書き起こし。Undo（FR-7）で復元する対象であり、
    /// **整形が間に合わなかったときに挿入されるテキストでもある。**
    public let rawText: String
    /// 整形後の書き起こし。整形せずに挿入した場合は nil。
    public let refinedText: String?
    public let localeIdentifier: String
    public let insertionMethod: InsertionMethod

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        rawText: String,
        refinedText: String?,
        localeIdentifier: String,
        insertionMethod: InsertionMethod
    ) {
        self.id = id
        self.timestamp = timestamp
        self.rawText = rawText
        self.refinedText = refinedText
        self.localeIdentifier = localeIdentifier
        self.insertionMethod = insertionMethod
    }

    /// 実際に挿入された文字列。
    public var insertedText: String { refinedText ?? rawText }

    /// **自動 Undo（FR-7）の候補になりうるか。**
    ///
    /// `refinedText != nil` と 10 秒窓だけでは足りない。**挿入経路を見ないと、
    /// 挿入していない発話まで候補になる**（carry-ins 項目 16）。
    ///
    /// | 経路 | 候補か | 理由 |
    /// |---|---|---|
    /// | `.ax` | **候補** | 範囲を持てる唯一の経路（設計 opus §2.2 の C-1） |
    /// | `.pasteboard` | 候補にしない | **貼り付いたことすら確認できない**（`CGEvent.post` は `Void`）。範囲も無い |
    /// | `.clipboardOnly` | 候補にしない | **挿入していない。** ここへ Undo を撃つと、挿入していないテキストを消そうとして**別の何かを消す** |
    /// | `.notInserted` | 候補にしない | ESC で中断された発話。戻すべき挿入が存在しない |
    ///
    /// - Important: **これは 2 番目の門であって、1 番目ではない。**
    ///   本当の門は**メモリ上に生きている `ReplacementAnchor`** である（設計 opus §3.2）。
    ///   錨は `.ax` 経路の挿入でしか作られず、ディスクへ持ち越されないので、
    ///   アプリを再起動した後の履歴から自動 Undo が撃たれることはない。
    ///   `HistoryStore.undoCandidate` もこの値を見る（配線トラックで接続済み）。
    public var isAutomaticUndoCandidate: Bool {
        guard refinedText != nil else { return false }
        switch insertionMethod {
        case .ax: return true
        case .pasteboard, .clipboardOnly, .notInserted: return false
        }
    }

    /// **自動では戻せないが、生テキストをクリップボードへ取り出せる発話か**
    /// （要件定義書 FR-7 の細目 3 行目 / UC-3 の縮退）。
    ///
    /// `isAutomaticUndoCandidate` と**ちょうど裏返しの経路**を拾う。整形結果が入って
    /// いるのに範囲を持てなかった発話——`.pasteboard` と `.clipboardOnly`——がこれで、
    /// FR-7 は「戻せる」を満たせないと認めたうえで**クリップボードへ逃がす**と定めている。
    ///
    /// - Important: **`.notInserted` は含まない。** 中断された発話は挿入されておらず、
    ///   `refinedText` も入らない（`DictationSession.finishCancelled`）。
    /// - Note: **クリップボードを奪うのは利用者の明示操作のときだけ**という前提に
    ///   立っている（Undo キーを押した瞬間にしか使わない）。
    public var isManualUndoFallbackCandidate: Bool {
        guard refinedText != nil else { return false }
        switch insertionMethod {
        case .pasteboard, .clipboardOnly: return true
        case .ax, .notInserted: return false
        }
    }
}
