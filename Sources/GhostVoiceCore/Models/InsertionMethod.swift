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
}
