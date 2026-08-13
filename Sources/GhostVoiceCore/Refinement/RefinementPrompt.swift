import Foundation

public enum RefinementPrompt {

    /// セッション生成時に一度だけ与える指示。
    ///
    /// 規則 4 は実測で確認された過剰要約（「エラーハンドリングが抜けてるので、
    /// そこを追加したい」→「エラーハンドリングを追加したい」）への対策。
    public static func instructions(for locale: Locale) -> String {
        let language = locale.language.languageCode?.identifier == "en" ? "English" : "日本語"
        return """
        あなたは音声入力テキストの整形器です。入力は \(language) です。
        以下の規則に従ってください。

        1. フィラー（えー、あの、まあ、その 等）を削除する
        2. 言い直しは、後から言い直した方を残す
        3. 句読点を適切に補う
        4. 話者の意図・情報を変更しない。要約しない。語を削らない
        5. 整形後のテキストのみを出力する。説明・前置き・引用符は付けない
        """
    }

    /// 発話ごとに組み立てるプロンプト。辞書が空なら辞書ブロックを省く。
    ///
    /// 固有名詞の精度対策はここだけが効く。`AnalysisContext.contextualStrings` は
    /// 実測で出力を 1 文字も変えなかったため、認識側にヒントを渡す手段は無い。
    public static func prompt(rawText: String, terms: [VocabularyTerm]) -> String {
        guard !terms.isEmpty else { return rawText }

        let listed = terms.prefix(VocabularyStore.maxTerms)
            .map(\.canonical)
            .joined(separator: ", ")

        return """
        以下の固有名詞が含まれる可能性があります。音が近い箇所はこの表記に直してください。
        \(listed)

        整形対象:
        \(rawText)
        """
    }
}
