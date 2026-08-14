import AppKit
import Carbon.HIToolbox
import Foundation

/// secure input 中でなければ AX 経路を試し、駄目なら Pasteboard 経路へ落とし、
/// それも駄目ならクリップボードへ残す。
///
/// AX は一部アプリ（Electron 製など）で無言失敗するため、経路を一本に絞れない（R-4）。
///
/// - Important: 一段目の「失敗」は **AX API のステータス**でしか判定できない。
///   成功を返しながら何も入らない無言失敗は素通りし、`.ax` として記録される
///   （`AccessibilityInserter` の注記を参照）。
///
/// ```
/// secure input が有効か
///   └─ 有効 → 何も試さず拒否 → .refusedSecureInput（クリップボードにも残さない）
/// AccessibilityInserter が適用可能か判定
///   ├─ 可 → 実行 → 成功: .inserted(.ax) / 失敗: 次へ
///   └─ 不可 → 次へ
/// PasteboardInserter が適用可能か判定 → 実行
///   ├─ 成功 → .inserted(.pasteboard)
///   └─ 失敗 → クリップボードへ残置 → .inserted(.clipboardOnly)
/// ```
public struct CompositeInserter: TextInserting {

    private let primary: any PrimaryInserting
    private let fallback: any PrimaryInserting
    private let lastResort: any ClipboardLeaving
    private let isSecureInputEnabled: @Sendable () -> Bool

    /// - Parameters:
    ///   - primary: 一段目。成功すると `.ax` を報告する。
    ///   - fallback: 二段目。成功すると `.pasteboard` を報告する。
    ///   - lastResort: 最後の砦。**省略できないようにしてある**（下記）。
    ///   - isSecureInputEnabled: secure input の判定。既定は実 API。
    public init(
        primary: any PrimaryInserting,
        fallback: any PrimaryInserting,
        lastResort: any ClipboardLeaving,
        isSecureInputEnabled: @escaping @Sendable () -> Bool = { IsSecureEventInputEnabled() }
    ) {
        self.primary = primary
        self.fallback = fallback
        self.lastResort = lastResort
        self.isSecureInputEnabled = isSecureInputEnabled
    }

    public func insert(_ text: String) async -> InsertionOutcome {
        // **secure input が有効な間は、どの経路も試さずに拒否する。**
        //
        // secure input が有効なのは、ユーザーがパスワードを入力しているときである。
        // secure input は「この瞬間の入力を捕まえるな」という OS からの明示的な合図で、
        // AX 経路でそれを迂回するのは機能ではなく欠陥である。
        //
        // 通したときに起きること:
        //   1. 発話が LLM 整形（`FoundationModels`）へ渡る
        //   2. **履歴ファイルへ平文で永続化される。** `HistoryStore` は `rawText` と
        //      `refinedText` を `history.json` に平文の JSON で保存する。
        //      要件定義書 NFR-V2 が禁じているのは音声のディスク書き出しなので、
        //      テキスト履歴はこの禁止を素通りする
        //   3. `.clipboardOnly` へ落ちればクリップボードにも残る
        //
        // **ここはこの製品で唯一「発話を失う」ことを正とする分岐である。**
        // 通常は発話を失わないことが最優先（基本設計書 §7）だが、
        // パスワードは残す方が害が大きい。クリップボードにも残さない。
        //
        // 判定は挿入のたびに行う。ユーザーはパスワード欄に出入りするので、
        // 起動時の値を握っていては意味が無い（実測 0.000 ms なので毎回呼べる）。
        guard !isSecureInputEnabled() else { return .refusedSecureInput }

        if primary.canInsert(), await primary.tryInsert(text) { return .inserted(.ax) }
        if fallback.canInsert(), await fallback.tryInsert(text) { return .inserted(.pasteboard) }

        // **`.clipboardOnly` を返す前に、実際にクリップボードへ残す。**
        //
        // 両段が `canInsert()` で「適用外」を返した場合、`tryInsert` は一度も走らない。
        // つまり Pasteboard 経路がクリップボードへ書く機会が無い。ここを塞がないと
        // 「クリップボードへ残した」と報告しながら発話がどこにも無い状態になる。
        // 音声は再現できないので、これはこの製品で最も重い失敗である（基本設計書 §7）。
        lastResort.leave(text)
        return .inserted(.clipboardOnly)
    }

    /// 本番の組み合わせ。
    ///
    /// **最後の砦は Pasteboard 経路と同じクリップボードを見ていなければならない。**
    /// 別の `NSPasteboard` を掴んだ最後の砦を組むと、残したテキストが
    /// ユーザーには見えない場所へ行く。同じインスタンスを二役で渡している。
    public static func system(
        accessibility: any AccessibilityProbing = SystemAccessibility(),
        pasteboard: NSPasteboard = .general,
        sender: any PasteShortcutSending = SystemPasteShortcutSender(),
        isSecureInputEnabled: @escaping @Sendable () -> Bool = { IsSecureEventInputEnabled() }
    ) -> CompositeInserter {
        let pasteboardInserter = PasteboardInserter(pasteboard: pasteboard, sender: sender)
        return CompositeInserter(
            primary: AccessibilityInserter(accessibility: accessibility),
            fallback: pasteboardInserter,
            lastResort: pasteboardInserter,
            isSecureInputEnabled: isSecureInputEnabled
        )
    }
}
