import AppKit
import Foundation

/// AX 経路を試し、駄目なら Pasteboard 経路へ落とし、それも駄目ならクリップボードへ残す。
///
/// AX は一部アプリ（Electron 製など）で無言失敗するため、経路を一本に絞れない（R-4）。
///
/// ```
/// AccessibilityInserter が適用可能か判定
///   ├─ 可 → 実行 → 成功: .ax / 失敗: 次へ
///   └─ 不可 → 次へ
/// PasteboardInserter が適用可能か判定 → 実行
///   ├─ 成功 → .pasteboard
///   └─ 失敗 → クリップボードへ残置 → .clipboardOnly
/// ```
public struct CompositeInserter: TextInserting {

    private let primary: any PrimaryInserting
    private let fallback: any PrimaryInserting
    private let lastResort: any ClipboardLeaving

    /// - Parameters:
    ///   - primary: 一段目。成功すると `.ax` を報告する。
    ///   - fallback: 二段目。成功すると `.pasteboard` を報告する。
    ///   - lastResort: 最後の砦。**省略できないようにしてある**（下記）。
    public init(
        primary: any PrimaryInserting,
        fallback: any PrimaryInserting,
        lastResort: any ClipboardLeaving
    ) {
        self.primary = primary
        self.fallback = fallback
        self.lastResort = lastResort
    }

    public func insert(_ text: String) async -> InsertionMethod {
        if primary.canInsert(), await primary.tryInsert(text) { return .ax }
        if fallback.canInsert(), await fallback.tryInsert(text) { return .pasteboard }

        // **`.clipboardOnly` を返す前に、実際にクリップボードへ残す。**
        //
        // 両段が `canInsert()` で「適用外」を返した場合、`tryInsert` は一度も走らない。
        // つまり Pasteboard 経路がクリップボードへ書く機会が無い。ここを塞がないと
        // 「クリップボードへ残した」と報告しながら発話がどこにも無い状態になる。
        // 音声は再現できないので、これはこの製品で最も重い失敗である（基本設計書 §230）。
        lastResort.leave(text)
        return .clipboardOnly
    }

    /// 本番の組み合わせ。
    ///
    /// **最後の砦は Pasteboard 経路と同じクリップボードを見ていなければならない。**
    /// 別の `NSPasteboard` を掴んだ最後の砦を組むと、残したテキストが
    /// ユーザーには見えない場所へ行く。同じインスタンスを二役で渡している。
    public static func system(
        accessibility: any AccessibilityProbing = SystemAccessibility(),
        pasteboard: NSPasteboard = .general,
        sender: any PasteShortcutSending = SystemPasteShortcutSender()
    ) -> CompositeInserter {
        let pasteboardInserter = PasteboardInserter(pasteboard: pasteboard, sender: sender)
        return CompositeInserter(
            primary: AccessibilityInserter(accessibility: accessibility),
            fallback: pasteboardInserter,
            lastResort: pasteboardInserter
        )
    }
}
