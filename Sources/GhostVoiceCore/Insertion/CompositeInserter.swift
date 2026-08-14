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
public struct CompositeInserter: AnchoringTextInserting {

    private let primary: any PrimaryInserting
    private let fallback: any PrimaryInserting
    private let lastResort: any ClipboardLeaving
    private let isSecureInputEnabled: @Sendable () -> Bool

    /// 挿入の世代。**差し替え器と共有する。**
    ///
    /// 新しい挿入が始まった時点で、保留中の差し替えを失効させるために持つ
    /// （設計 opus §3.3「直列性と後始末」）。
    public let epoch: InsertionEpoch

    /// - Parameters:
    ///   - primary: 一段目。成功すると `.ax` を報告する。
    ///   - fallback: 二段目。成功すると `.pasteboard` を報告する。
    ///   - lastResort: 最後の砦。**省略できないようにしてある**（下記）。
    ///   - epoch: 挿入の世代。`TextReplacer` へ同じものを渡すこと。
    ///   - isSecureInputEnabled: secure input の判定。既定は実 API。
    public init(
        primary: any PrimaryInserting,
        fallback: any PrimaryInserting,
        lastResort: any ClipboardLeaving,
        epoch: InsertionEpoch = InsertionEpoch(),
        isSecureInputEnabled: @escaping @Sendable () -> Bool = { IsSecureEventInputEnabled() }
    ) {
        self.primary = primary
        self.fallback = fallback
        self.lastResort = lastResort
        self.epoch = epoch
        self.isSecureInputEnabled = isSecureInputEnabled
    }

    /// テキストを挿入し、経路と**差し替えの錨**を返す。
    ///
    /// - Important: **呼ばれた時点で、前の発話の差し替えは失効する**（世代が進む）。
    ///   拒否された場合も同じ。**失効しても生テキストは欄に残る**ので、
    ///   縮退の向きは常に安全側である。
    public func insertCapturingAnchor(_ text: String) async -> AnchoredInsertion {
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
        //
        // **世代を進めるのは判定より前。** 拒否された場合も前の錨を失効させる。
        // 失効の縮退先は「差し替えない」＝生テキストが欄に残る、なので安全側である。
        epoch.advance()

        guard !isSecureInputEnabled() else {
            return AnchoredInsertion(outcome: .refusedSecureInput, anchor: nil)
        }

        if primary.canInsert() {
            let attempt = await primary.tryInsert(text)
            if attempt.didInsert {
                return AnchoredInsertion(outcome: .inserted(.ax), anchor: attempt.anchor)
            }
        }
        if fallback.canInsert() {
            let attempt = await fallback.tryInsert(text)
            if attempt.didInsert {
                // **二段目の錨は受け取らない**（設計 opus §2.2 の C-1）。
                // Pasteboard 経路は範囲を持てず、貼り付いたことすら確認できない
                // （`CGEvent.post` は `Void`）。ここを通すと、位置の算術だけを頼りに
                // 他アプリのテキストを書き換える経路ができる。
                return AnchoredInsertion(outcome: .inserted(.pasteboard), anchor: nil)
            }
        }

        // **`.clipboardOnly` を返す前に、実際にクリップボードへ残す。**
        //
        // 両段が `canInsert()` で「適用外」を返した場合、`tryInsert` は一度も走らない。
        // つまり Pasteboard 経路がクリップボードへ書く機会が無い。ここを塞がないと
        // 「クリップボードへ残した」と報告しながら発話がどこにも無い状態になる。
        // 音声は再現できないので、これはこの製品で最も重い失敗である（基本設計書 §7）。
        lastResort.leave(text)
        return AnchoredInsertion(outcome: .inserted(.clipboardOnly), anchor: nil)
    }

    /// 本番の組み合わせ。
    ///
    /// **最後の砦は Pasteboard 経路と同じクリップボードを見ていなければならない。**
    /// 別の `NSPasteboard` を掴んだ最後の砦を組むと、残したテキストが
    /// ユーザーには見えない場所へ行く。同じインスタンスを二役で渡している。
    ///
    /// - Parameter restoreDelay: ⌘V の送出からクリップボードを戻すまでの待ち。
    ///   **実測 35 ms は下限であり上限ではない**（`PasteboardInserter.defaultRestoreDelay`
    ///   の留保 2 つ）。相手が重いアプリで貼り付けが空振りするなら、ここを延ばして試す。
    public static func system(
        accessibility: any ReplacementCapableAccessibility = SystemAccessibility(),
        pasteboard: NSPasteboard = .general,
        sender: any PasteShortcutSending = SystemPasteShortcutSender(),
        restoreDelay: Duration = PasteboardInserter.defaultRestoreDelay,
        epoch: InsertionEpoch = InsertionEpoch(),
        isSecureInputEnabled: @escaping @Sendable () -> Bool = { IsSecureEventInputEnabled() }
    ) -> CompositeInserter {
        let pasteboardInserter = PasteboardInserter(
            pasteboard: pasteboard, sender: sender, restoreDelay: restoreDelay)
        return CompositeInserter(
            primary: AccessibilityInserter(accessibility: accessibility, epoch: epoch),
            fallback: pasteboardInserter,
            lastResort: pasteboardInserter,
            epoch: epoch,
            isSecureInputEnabled: isSecureInputEnabled
        )
    }
}

/// 挿入器と差し替え器の組。**この 2 つは必ず一緒に作る。**
///
/// 別々に作ると次の 2 つを間違える。どちらも黙って壊れる形の間違いである。
///
/// - **世代（`InsertionEpoch`）を共有しないと**、差し替えが常に「失効した」と判定され、
///   FR-5(a) も FR-7 も一度も効かない（症状は「整形が反映されない」だけ）。
/// - **クリップボードを共有しないと**、喪失を検知したときの退避先が
///   ユーザーには見えない `NSPasteboard` になる（症状は「発話が消えた」）。
public struct InsertionStack: Sendable {
    public let inserter: CompositeInserter
    public let replacer: TextReplacer

    public init(inserter: CompositeInserter, replacer: TextReplacer) {
        self.inserter = inserter
        self.replacer = replacer
    }
}

extension CompositeInserter {
    /// 本番の組み立て。**挿入と差し替えを、同じ世代・同じクリップボードで組む。**
    ///
    /// ```swift
    /// let stack = CompositeInserter.systemStack(announcer: hud)
    /// let inserted = await stack.inserter.insertCapturingAnchor(rawText)
    /// // …整形を待って…
    /// if let anchor = inserted.anchor { _ = stack.replacer.replace(anchor, with: refined) }
    /// ```
    ///
    /// - Parameter announcer: 喪失を検知したときに利用者へ告げる口（HUD）。
    ///   省略すると何も告げない。**告げなくても発話はクリップボードと履歴にある。**
    public static func systemStack(
        accessibility: any ReplacementCapableAccessibility = SystemAccessibility(),
        pasteboard: NSPasteboard = .general,
        sender: any PasteShortcutSending = SystemPasteShortcutSender(),
        restoreDelay: Duration = PasteboardInserter.defaultRestoreDelay,
        announcer: any ReplacementAnnouncing = SilentAnnouncer(),
        isSecureInputEnabled: @escaping @Sendable () -> Bool = { IsSecureEventInputEnabled() }
    ) -> InsertionStack {
        let epoch = InsertionEpoch()
        let pasteboardInserter = PasteboardInserter(
            pasteboard: pasteboard, sender: sender, restoreDelay: restoreDelay)
        let inserter = CompositeInserter(
            primary: AccessibilityInserter(accessibility: accessibility, epoch: epoch),
            fallback: pasteboardInserter,
            lastResort: pasteboardInserter,
            epoch: epoch,
            isSecureInputEnabled: isSecureInputEnabled
        )
        let replacer = TextReplacer(
            accessibility: accessibility,
            // **挿入器と同じ `NSPasteboard` を掴んだ砦を渡す。**
            clipboard: pasteboardInserter,
            announcer: announcer,
            epoch: epoch,
            isSecureInputEnabled: isSecureInputEnabled
        )
        return InsertionStack(inserter: inserter, replacer: replacer)
    }
}
