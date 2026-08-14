import Foundation
import GhostVoiceCore
import Testing

@testable import GhostVoiceApp

/// **FR-11「辞書を設定画面から変更できる」の未達分**（誤認識表記の編集）。
///
/// 辞書は FR-6（誤認識の修正）の入力であり、**`RefinementGuard` が
/// 「頼んだ置換」と「逸脱」を区別する根拠**でもある（正本 §5.5.1）。
/// 誤認識表記を編集できないと、FR-6 に何も入力できない。
@Suite("設定画面のユーザー辞書（FR-11 / FR-6）")
@MainActor
struct SettingsVocabularyTests {

    // MARK: - 入力欄と配列の翻訳

    @Test("区切り文字で並べた入力を配列へ戻す")
    func parsesSeparatedInput() {
        #expect(MisheardListText.list("ぎっと / ギット") == ["ぎっと", "ギット"])
        // 読点と改行も受ける（日本語の表記を並べる利用者は `、` を打つ）。
        #expect(MisheardListText.list("ぎっと、ギット\nギッド") == ["ぎっと", "ギット", "ギッド"])
    }

    /// **掃除をするのはここが唯一の場所である。**
    /// `VocabularyStore.normalize` は `canonical` しか見ないので、
    /// 空文字が整形プロンプトへ注入されると `RefinementGuard` の根拠が濁る。
    @Test("空白だけの項目を落とし、重複を先勝ちで畳む")
    func cleansTheInput() {
        #expect(MisheardListText.list(" / /  ").isEmpty)
        #expect(MisheardListText.list("ギット / ギット / ぎっと") == ["ギット", "ぎっと"])
        #expect(MisheardListText.list("  ギット  ") == ["ギット"])
        #expect(MisheardListText.list("") .isEmpty)
    }

    @Test("配列 → 入力欄 → 配列で往復する")
    func roundTripsThroughTheField() {
        let original = ["ぎっと", "ギット", "ギッド"]
        #expect(MisheardListText.list(MisheardListText.text(original)) == original)
    }

    // MARK: - 画面からの編集

    @Test("誤認識表記を編集できる（**保存するまでディスクは変わらない**）")
    func editsMisheardWithoutSaving() throws {
        let temp = try SettingsHistoryTempDirectory()
        let model = try makeModel(in: temp)

        model.addTerm()
        model.setCanonical("Git", at: 0)
        model.setMisheard("ぎっと / ギット", at: 0)

        #expect(model.vocabularyTerms == [VocabularyTerm(canonical: "Git", misheard: ["ぎっと", "ギット"])])
        #expect(model.misheardText(at: 0) == "ぎっと / ギット")
        #expect(!temp.exists("vocabulary.json"), "保存していないのに書いている")
        #expect(model.hasUnsavedChanges)
    }

    @Test("編集した辞書が保存され、読み直しても残る")
    func savedVocabularySurvivesAReload() async throws {
        let temp = try SettingsHistoryTempDirectory()
        let model = try makeModel(in: temp)

        model.addTerm()
        model.setCanonical("Ghost Voice", at: 0)
        model.setMisheard("ゴーストボイス / ごーすとぼいす", at: 0)
        await model.save()

        let reloaded = VocabularyStore(rootURL: temp.url)
        #expect(
            reloaded.terms
                == [
                    VocabularyTerm(
                        canonical: "Ghost Voice", misheard: ["ゴーストボイス", "ごーすとぼいす"])
                ])
    }

    /// **正しい表記だけを空にしても、誤認識表記は消えない**——
    /// `VocabularyStore.normalize` が項目ごと落とすのは保存のときである。
    /// 画面の途中の状態でうっかり消さない。
    @Test("正しい表記を空にしても、途中の編集内容は保たれる")
    func emptyCanonicalKeepsTheDraft() throws {
        let temp = try SettingsHistoryTempDirectory()
        let model = try makeModel(in: temp)

        model.addTerm()
        model.setMisheard("ぎっと", at: 0)
        model.setCanonical("", at: 0)

        #expect(model.vocabularyTerms[0].misheard == ["ぎっと"])
    }

    @Test("空の項目は保存のときに落ちる（Core の正規化がそのまま効く）")
    func emptyTermsAreDroppedOnSave() async throws {
        let temp = try SettingsHistoryTempDirectory()
        let model = try makeModel(in: temp)

        model.addTerm()  // 空のまま
        model.addTerm()
        model.setCanonical("Git", at: 1)
        await model.save()

        #expect(VocabularyStore(rootURL: temp.url).terms == [VocabularyTerm(canonical: "Git")])
    }

    @Test("項目を削除できる")
    func removesTerms() throws {
        let temp = try SettingsHistoryTempDirectory()
        let model = try makeModel(in: temp)

        model.addTerm()
        model.setCanonical("A", at: 0)
        model.addTerm()
        model.setCanonical("B", at: 1)
        model.removeTerm(at: 0)

        #expect(model.vocabularyTerms.map(\.canonical) == ["B"])
        // 範囲外は黙って無視する（並べ替えと削除が競っても落ちない）。
        model.removeTerm(at: 9)
        #expect(model.vocabularyTerms.count == 1)
    }

    @Test("範囲外の添字で編集しても落ちない")
    func outOfRangeEditsAreIgnored() throws {
        let temp = try SettingsHistoryTempDirectory()
        let model = try makeModel(in: temp)

        model.setCanonical("A", at: 3)
        model.setMisheard("B", at: 3)
        #expect(model.vocabularyTerms.isEmpty)
        #expect(model.misheardText(at: 3) == "")
    }

    private func makeModel(in temp: SettingsHistoryTempDirectory) throws -> SettingsViewModel {
        SettingsViewModel(
            settings: SettingsStore(rootURL: temp.url),
            vocabulary: VocabularyStore(rootURL: temp.url),
            history: HistoryStore(rootURL: temp.url, limit: 50),
            session: nil,
            directory: temp.url)
    }
}
