import AppKit
import Foundation
import GhostVoiceCore

/// **履歴画面が外へテキストを出す口**（FR-9 の「再挿入・コピー」）。
///
/// 挿入とコピーを 1 つの面にまとめてあるのは、**同じクリップボードを見ていなければ
/// ならない**からである（`InsertionStack` の注記と同じ理由）。別々に組むと、
/// 挿入が全滅して `.clipboardOnly` に落ちたときの退避先と、
/// 「コピー」ボタンが書く先が別の `NSPasteboard` になる。
public protocol HistoryTextOutput: Sendable {
    /// 前面のアプリへ挿入する。
    ///
    /// - Important: **`.refusedSecureInput` が返りうる。** そのときテキストは
    ///   どこにも残っていない（クリップボードにも置いていない）。**画面はそれを
    ///   「失敗」ではなく「拒否」として出すこと**（要件定義書 FR-4 の例外）。
    func insert(_ text: String) async -> InsertionOutcome

    /// クリップボードへ置く。置けたら true。
    func copy(_ text: String) -> Bool
}

/// 本物の挿入器とクリップボードを束ねた口。
///
/// - Important: **発話の挿入に使っている組（`InsertionStack`）をそのまま共有する。**
///   別に組むと `InsertionEpoch` が別インスタンスになり、
///
///   1. **再挿入の AX 書き込みが、保留中の差し替えの AX 書き込みと直列化されない**
///      （錠は世代のインスタンスに属する）。`TextReplacer` の手順 2〜4 の間に
///      同じ欄の前方へ書かれると、**記録済みの範囲がずれたまま上書きが走り、
///      利用者の別のテキストが整形結果で消える。**
///   2. **再挿入が発話側の錨を失効させない**（世代が別なので `.staleEpoch` が立たない）。
///
///   直前まで前者の説明が逆に書かれており（「失効させるだけ」）、
///   **その誤った前提が「別インスタンスでよい」という判断を支えていた**（再レビュー B-2 / D）。
///
///   共有すると、再挿入は保留中の差し替えを `.staleEpoch` で降ろす。
///   **縮退先は「差し替えない」＝生テキストが欄に残る**で、安全側である。
///   再挿入で差し替えの錨を作らないのは変わらない（`insert` は `TextInserting` の口を
///   通るので錨を返さない）——再挿入は「もう一度打ち直す」操作であって発話の続きではない。
public struct SystemHistoryTextOutput: HistoryTextOutput {
    private let inserter: any TextInserting
    private let clipboard: any ClipboardLeaving

    public init(inserter: any TextInserting, clipboard: any ClipboardLeaving) {
        self.inserter = inserter
        self.clipboard = clipboard
    }

    /// 本番の組み立て。**セッションが使っている組を渡すこと**（上の注記）。
    ///
    /// - Parameter stack: 発話の挿入・差し替えに使っている組。
    ///   **nil を渡してよいのは「セッションが 1 つも無いとき」だけである**
    ///   （`--shell-only` / キー監視を開始できなかったとき）。そのときは保留中の
    ///   差し替えが存在しえないので、独立した世代を作っても壊れる不変条件が無い。
    /// - Important: **検査から呼んではならない。** nil を渡すと本物の
    ///   `CGEvent.post` と AX 書き込みが走り、**そのとき前面にあるアプリへ文字が出る**
    ///   （`COMMON.md` の安全制約）。検査は `HistoryTextOutput` の代役か、
    ///   代役で組んだ `InsertionStack` を渡すこと。
    public static func system(sharing stack: InsertionStack?) -> SystemHistoryTextOutput {
        let stack = stack ?? CompositeInserter.systemStack()
        return SystemHistoryTextOutput(inserter: stack.inserter, clipboard: stack.clipboard)
    }

    public func insert(_ text: String) async -> InsertionOutcome {
        await inserter.insert(text)
    }

    public func copy(_ text: String) -> Bool {
        clipboard.leave(text)
    }
}
