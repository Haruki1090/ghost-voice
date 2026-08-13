import Testing
import Foundation
@testable import GhostVoiceCore

@Suite("RefinementPrompt")
struct RefinementPromptTests {

    private func instructionLines(_ locale: String) -> [String] {
        RefinementPrompt.instructions(for: Locale(identifier: locale))
            .split(separator: "\n")
            .map(String.init)
    }

    /// `contains` だけだと規則が 1 つ消えても他の規則の文言で素通りする。
    /// 番号付きの行として何番に何が書かれているかを固定する。
    @Test("instructions に 5 つの規則が番号どおりに並ぶ")
    func listsAllRulesInOrder() {
        let lines = instructionLines("ja-JP")
        func rule(_ number: Int) -> String? {
            lines.first { $0.hasPrefix("\(number). ") }
        }

        #expect(rule(1)?.contains("フィラー") == true)
        #expect(rule(2)?.contains("言い直") == true)
        #expect(rule(3)?.contains("句読点") == true)
        // 規則 4 は実測された過剰要約への対策。消えると壊れることを明示する。
        #expect(rule(4)?.contains("要約しない") == true)
        #expect(rule(4)?.contains("変更しない") == true)
        #expect(rule(5)?.contains("整形後のテキストのみ") == true)
        #expect(rule(6) == nil, "規則は 5 つのはず: \(lines)")
    }

    @Test("入力言語をロケールから決める")
    func statesInputLanguage() {
        #expect(instructionLines("ja-JP").contains { $0.contains("入力は 日本語 です") })
        #expect(instructionLines("en-US").contains { $0.contains("入力は English です") })
    }

    /// 辞書ブロックを付けないとは、余計な枠を一切足さないということ。
    /// 完全一致で固定しないと「常に何も足さない」実装でも通ってしまう
    /// （`includesCanonicalTerms` が対になって、その実装を落とす）。
    @Test("辞書が空なら整形対象をそのまま渡す")
    func omitsVocabularyBlockWhenEmpty() {
        #expect(RefinementPrompt.prompt(rawText: "テスト発話", terms: []) == "テスト発話")
    }

    @Test("辞書があれば正規表記を列挙する")
    func includesCanonicalTerms() {
        let terms = [
            VocabularyTerm(canonical: "Nexadata"),
            VocabularyTerm(canonical: "microCMS", misheard: ["マイクロシーエムエス"]),
        ]
        let prompt = RefinementPrompt.prompt(rawText: "ネクサデータの件です", terms: terms)

        #expect(prompt.contains("固有名詞"))
        #expect(prompt.contains("Nexadata, microCMS"))
        #expect(prompt.contains("整形対象:\nネクサデータの件です"))
    }

    /// 辞書は毎回プロンプトへ載るのでレイテンシに直結する。
    /// 「100 語まで」を件数で数え、上限が 99 でも 150 でも落ちるようにする。
    @Test("辞書が 100 語を超えても 100 語までしか出力しない")
    func capsVocabularyAtMax() {
        let terms = (0..<150).map { VocabularyTerm(canonical: "Term\($0)") }
        let prompt = RefinementPrompt.prompt(rawText: "発話", terms: terms)

        let listed = prompt.split(separator: "\n").first { $0.hasPrefix("Term0, ") }
        let names = (listed?.components(separatedBy: ", ") ?? [])
        #expect(names.count == 100)
        #expect(names.count == VocabularyStore.maxTerms)
        #expect(names.last == "Term99")
        #expect(!prompt.contains("Term100"))
        #expect(prompt.contains("発話"))
    }
}
