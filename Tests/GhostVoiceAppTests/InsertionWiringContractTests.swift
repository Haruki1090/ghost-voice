import Foundation
import Testing

/// **本番の組み立てが「差し替えられる形」になっていることを固定する。**
///
/// フェーズ 2 の最終レビューで見つかった最大の欠陥は、
/// **本番の 2 箇所が古い初期化子（`inserter:`）を呼んでいて、
/// `replacer` / `clipboard` が nil のままだった**ことである。
/// 症状は「FR-5(a) の差し替えと FR-7 の Undo が製品では一度も動かない」で、
/// **検査は 1 件も落ちなかった**——検査が自分で正しい組（`InsertionStack`）を作っていたためである。
///
/// したがって守るべき命題は「Core が正しく組める」ではなく
/// **「製品の 2 つの組み立てが、実際にその正しい組を通っている」**である。
///
/// - Note: 組み立ての**結果**（差し替えできるセッションになるか）は
///   `GhostVoiceCoreTests` の `ProductionInsertionStackTests` が見る。
///   こちらはソースの走査で、**製品の 2 箇所がその式を呼んでいること**だけを見る。
@Suite("挿入スタックの配線（本番の組み立て）")
struct InsertionWiringContractTests {

    /// リポジトリの根。**テストの置き場所から辿る**（作業ディレクトリに依存しない）。
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // GhostVoiceAppTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // リポジトリの根

    /// コメント行を落としたソース。**注記の中の文字列を数えないため。**
    static func sourceWithoutComments(_ relativePath: String) throws -> String {
        let text = try String(
            contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
        return
            text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// 本番の組み立て 2 箇所。**片方だけ直しても、もう片方で同じ欠陥が残る。**
    static let productionAssemblies = [
        "Sources/GhostVoiceApp/Shell/AppSessionRuntime.swift",
        "Sources/GhostVoiceCLI/GhostVoiceRuntime.swift",
    ]

    /// - Note: **「`insertion:` の直後に `systemStack(` が来る」という形では見ない。**
    ///   `.app` は組を 1 度だけ作って**履歴画面の再挿入にも同じものを渡す**ようになった
    ///   （再レビュー B-2。別に組むと AX 書き込みの錠が 2 つになる）ため、
    ///   組み立てが `let insertion = CompositeInserter.systemStack()` と
    ///   `insertion: insertion` の 2 行に分かれる。**命題は「その組を渡していること」**
    ///   であって行の並びではないので、2 つを別々に見る。
    ///   組の**型**（差し替え器つき）はコンパイラが保証する（公開初期化子は
    ///   `insertion: InsertionStack` しか受け取らない。下の検査）。
    @Test(
        "本番の組み立ては InsertionStack（差し替え器つき）を渡す",
        arguments: InsertionWiringContractTests.productionAssemblies
    )
    func productionPassesTheInsertionStack(path: String) throws {
        let code = try Self.sourceWithoutComments(path)
        #expect(
            code.contains("CompositeInserter.systemStack("),
            "\(path) が本番の組み立て（systemStack）を通っていない")
        #expect(
            code.contains("insertion:"),
            "\(path) が差し替え器つきの組（InsertionStack）を渡していない")
        #expect(
            !code.contains("inserter: CompositeInserter.system("),
            "\(path) が古い初期化子（差し替え器が nil になる方）を呼んでいる")
    }

    /// **罠そのものを残さない**（統括の裁定）。
    ///
    /// 呼び出し 2 箇所を直すだけでは、次に組み立てを書く人が同じ穴へ落ちる。
    /// `DictationSession` の**公開された**初期化子は `insertion:` を要求するものだけにし、
    /// 差し替え器を省ける口は `internal`（＝本番ターゲットからは見えない）にしてある。
    @Test("DictationSession の公開初期化子は差し替え器を省けない")
    func onlyPublicInitializerRequiresTheStack() throws {
        let code = try Self.sourceWithoutComments(
            "Sources/GhostVoiceCore/Session/DictationSession.swift")
        let publicInits = code.components(separatedBy: "public init(").count - 1
        #expect(publicInits == 1, "公開初期化子が \(publicInits) 個ある（1 個であること）")
        #expect(code.contains("insertion: InsertionStack"))
        // 差し替え器を省ける口は「テスト専用と判る名前」の internal な工場に閉じてある。
        #expect(
            code.contains("static func forTests("),
            "テスト専用の口が『テスト専用と判る名前』になっていない")
        #expect(
            !code.contains("public static func forTests("),
            "テスト専用の口が公開されている（本番から到達できてしまう）")
    }
}
