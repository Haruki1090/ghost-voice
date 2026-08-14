import AppKit
import ApplicationServices
import Foundation
import GhostVoiceCore
import Testing

@testable import GhostVoiceApp

/// **AX への書き込みは、アプリ全体で 1 つの錠に直列化されていなければならない。**
///
/// 直前の修正巡回は「挿入と差し替えを `InsertionEpoch.withExclusiveWrite` で直列化する」を
/// 新しい不変条件にした。**その錠は `InsertionEpoch` のインスタンスに属する。**
/// ところが FR-9 の再挿入は `CompositeInserter.systemStack()` を**別に**組んでいたので、
///
/// 1. 再挿入の AX 書き込みが、保留中の差し替えの AX 書き込みと直列化されない
/// 2. 再挿入が発話側の錨を失効させない（世代が別なので `.staleEpoch` が立たない）
///
/// という形で**不変条件の外にあった**（再レビュー B-2）。
/// `TextReplacer` の手順 2（読み戻して一致を確かめる）から手順 4（上書き）までの間に
/// 別の錠を持つ書き込みが同じ欄の前方へ入ると、**記録済みの範囲がずれたまま
/// 手順 4 が走り、利用者の別のテキストが整形結果で上書きされる。**
@Suite("AX 書き込みの錠は 1 つ（履歴の再挿入も含む）")
struct InsertionEpochSharingTests {

    private static let appRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // GhostVoiceAppTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // リポジトリの根
        .appendingPathComponent("Sources/GhostVoiceApp")

    private static func text(_ relativePath: String) throws -> String {
        try String(contentsOf: appRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// doc コメントの中の言及は数えない（**禁止の理由を書くために名前が出る**）。
    private static func code(_ text: String) -> String {
        text.components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    @Test("走査の対象が実在する（空集合に対して緑になっていない）")
    func scanTargetsExist() throws {
        for path in ["Shell/Windows/StatusMenuSurface.swift", "Shell/AppSessionRuntime.swift"] {
            #expect(try !Self.text(path).isEmpty, "\(path) が無い")
        }
    }

    // MARK: - 命題 1: 履歴画面へ渡す口は、発話が使っている組から作る

    /// **`SystemHistoryTextOutput.system()` を引数なしで呼んではならない。**
    /// 呼んだ時点で `InsertionEpoch` が新しく作られ、錠が 2 つになる。
    @Test("履歴画面の出力口は、セッションが使っている組を渡して作る")
    func historyOutputSharesTheSessionStack() throws {
        let source = Self.code(try Self.text("Shell/Windows/StatusMenuSurface.swift"))
        #expect(
            source.contains("SystemHistoryTextOutput.system(sharing: services.insertion)"),
            "履歴画面の出力口が、セッションの組を共有しない形で作られている")
        #expect(
            !source.contains("SystemHistoryTextOutput.system()"),
            "引数なしの組み立て（別の世代・別の錠になる）を呼んでいる")
    }

    /// セッションを作った側が、その組を持ち回っていること。
    @Test("セッションの組は、作った側が持ち回って画面へ渡せる")
    func theRuntimeKeepsItsStack() throws {
        let source = Self.code(try Self.text("Shell/AppSessionRuntime.swift"))
        #expect(source.contains("let insertion"), "組を持ち回っていない（画面へ渡せない）")
        let delegate = Self.code(try Self.text("Shell/GhostVoiceAppDelegate.swift"))
        #expect(
            delegate.contains("insertion: runtime?.insertion"),
            "画面へ渡す一式（AppServices）へ組を載せていない")
    }

    // MARK: - 命題 2: 共有した組では、再挿入が保留中の差し替えを失効させる

    /// **これが「同じ錠・同じ世代である」ことの振る舞いによる証明である。**
    ///
    /// 再挿入は `CompositeInserter.insert` を通り、その先頭で `epoch.advance()` が走る。
    /// 世代を共有していれば、**保留中の差し替えは `.staleEpoch` で降りる**
    /// （欄は書き換わらない＝生テキストがそのまま残る。安全側の縮退）。
    /// 共有していなければ、差し替えは何事も無かったように書き込みへ進む。
    @Test("共有した組では、再挿入が保留中の差し替えの錨を失効させる")
    func reinsertionInvalidatesThePendingAnchor() async throws {
        try await withNamedPasteboard { pasteboard in
            let stack = Self.makeStack(pasteboard: pasteboard)
            let inserted = await stack.inserter.insertCapturingAnchor("えー、生テキストです")
            let anchor = try #require(inserted.anchor, "錨が取れていない（前提が崩れている）")

            // **セッションが使っているのと同じ組から、履歴画面の口を作る。**
            let output = SystemHistoryTextOutput.system(sharing: stack)
            _ = await output.insert("履歴から再挿入したテキスト")

            #expect(
                Self.isStale(stack.replacer.replace(anchor, with: "生テキストです。")),
                "再挿入が発話側の錨を失効させていない（世代を共有していない）")
        }
    }

    /// 共有しなければ失効しない——**上の検査が何を捕まえているか**を示す対照である。
    @Test("別に組んだ口では、再挿入が錨を失効させない（＝欠陥の形）")
    func aSeparatelyBuiltOutputDoesNotInvalidateTheAnchor() async throws {
        try await withNamedPasteboard { pasteboard in
            let stack = Self.makeStack(pasteboard: pasteboard)
            let inserted = await stack.inserter.insertCapturingAnchor("えー、生テキストです")
            let anchor = try #require(inserted.anchor)

            // **別の組**（＝直前まで本番がしていたこと）。
            let other = Self.makeStack(pasteboard: pasteboard)
            let output = SystemHistoryTextOutput.system(sharing: other)
            _ = await output.insert("履歴から再挿入したテキスト")

            #expect(
                !Self.isStale(stack.replacer.replace(anchor, with: "生テキストです。")),
                "別の組なのに失効した（この対照が意味を失っている）")
        }
    }

    // MARK: - 道具

    /// **実 AX も実 ⌘V も通らない。** 継ぎ目はすべて代役である（`COMMON.md` の安全制約）。
    private static func makeStack(pasteboard: NSPasteboard) -> InsertionStack {
        let field = FakeTextField(
            content: "前置きの文。その後の本文。",
            selection: AXTextRange(location: "前置きの文。".count, length: 0),
            caret: .endOfWrittenText
        )
        let element = FakeAccessibility.Element(
            role: kAXTextAreaRole as String, isSelectedTextSettable: true,
            processIdentifier: 424_242, acceptsWrite: true,
            isSelectedTextRangeSettable: true, identity: Self.fieldIdentity
        )
        return CompositeInserter.systemStack(
            accessibility: FakeAccessibility(focused: element, field: field),
            pasteboard: pasteboard,
            // **⌘V は送れない相手にしておく**（安全制約。実キーは 1 度も出さない）。
            sender: StubPasteShortcutSender(canSend: false),
            ownProcessIdentifier: 4_242,
            frontmostProcessIdentifier: { 424_242 },
            isSecureInputEnabled: { false }
        )
    }

    /// **2 つの組が同じ欄を指すようにする。** 別の欄だと `.staleEpoch` より先に
    /// C-4（別の入力欄）で降りてしまい、見たいものを見ない。
    private static let fieldIdentity = UUID()

    /// `ReplacementResult` は `Equatable` ではない（`.replaced` が錨を運ぶ）。
    private static func isStale(_ result: ReplacementResult) -> Bool {
        if case .declined(.staleEpoch) = result { return true }
        return false
    }
}

/// テスト専用の名前付きクリップボードを作り、`body` の後に必ず解放する。
///
/// **テストが `NSPasteboard.general` に触れてはならない。** 開発機で `swift test` を
/// 回した瞬間に利用者のクリップボードが消えることになる。
func withNamedPasteboard<R>(_ body: (NSPasteboard) async throws -> R) async rethrows -> R {
    let pasteboard = NSPasteboard(name: .init("gv-app-test-\(UUID().uuidString)"))
    defer { pasteboard.releaseGlobally() }
    return try await body(pasteboard)
}
