import Foundation

public enum RefinementPrompt {

    /// セッション生成時に一度だけ与える指示。
    ///
    /// **規則 4 は過剰要約（L-5）の対策として書いたが、実測で効いていない。**
    /// 対策として数えないこと（要件定義書 §2.8 L-5 / R-3）。規則 4 がある状態で
    /// 「えー、エラーハンドリングが抜けてるので、そこを追加したいです」→
    /// 「エラーハンドリングを追加します。」と、理由の情報が消えるのを再現した。
    ///
    /// 過剰要約に対する実効的な安全網は Undo（FR-7。**自動で戻せるのは差し替えできる
    /// 経路で挿入した発話に限る**）である。`RefinementGuard` でも
    /// 捕まえられない — 見ているのは長さの上限と**足された語**で、過剰要約は
    /// 「消す」方向なので、フィラー除去による正常な短縮（実測で 出力/入力 = 0.53 の
    /// 例がある）と区別が付かない。
    ///
    /// **規則 6「入力が文の途中で終わっていても、続きを補わない。入力に無い語を足さない」も
    /// 実測で効かなかった**（2026-08-15。文の途中で切れた 5 発話 × 3 回で、
    /// **出力が 1 文字も変わらなかった**）。だから足していない。
    /// **これで規則による対策が効かなかった例が 2 つになった**（規則 4 と規則 6）。
    /// **モデルが続きを捏造する経路の受け手は `RefinementGuard` だけである**
    /// （要件定義書 §2.8.7 / 詳細設計書 §5.5.1）。
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
    /// **`整形対象:` の枠は辞書の有無に関わらず必ず付ける。** 発話を裸で渡すと、
    /// 命令文に読める発話（「この関数にエラー処理を追加したい」等）でモデルが整形ではなく
    /// **その依頼への回答**を返す。実測（新規セッション・temperature 0・5 発話）では、
    /// 裸で渡すと 4/5 が逸脱し、枠で包むと 1/5 に下がった。
    ///
    /// 枠を付けても逸脱は残る。原因は「1 ターンのユーザーメッセージとして命令文を渡せば、
    /// `instructions` よりその場の指示が勝つことがある」という LLM 一般の性質にあり、
    /// 枠はその寄与を減らすだけで消しはしない。**残りは `RefinementGuard` が受け止める。**
    ///
    /// 固有名詞の精度対策はここだけが効く。`AnalysisContext.contextualStrings` は
    /// 実測で出力を 1 文字も変えなかったため、認識側にヒントを渡す手段は無い（要件定義書 FR-6）。
    ///
    /// 誤認識表記は「誤 → 正」の**方向付きの写像**として渡す。正規表記を並べるだけだと
    /// どの語をどう直すかの判断が LLM 側に残るが、写像なら置換の対象が名指しされる。
    /// `misheard` はユーザーが実際に誤変換を観測して書いたものなので、候補としての精度も高い。
    public static func prompt(rawText: String, terms: [VocabularyTerm]) -> String {
        let capped = terms.prefix(VocabularyStore.maxTerms)

        var blocks: [String] = []
        if !capped.isEmpty {
            blocks.append("""
            以下の固有名詞が含まれる可能性があります。音が近い箇所はこの表記に直してください。
            \(capped.map(\.canonical).joined(separator: ", "))
            """)
        }

        // 辞書はユーザーが手で編集する前提なので、空文字の誤認識表記が書かれうる。
        // 「 → microCMS」のような指示先の無い写像を LLM へ渡さない。
        let corrections = capped.compactMap { term -> String? in
            let variants = term.misheard
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard !variants.isEmpty else { return nil }
            return "\(variants.joined(separator: ", ")) → \(term.canonical)"
        }
        if !corrections.isEmpty {
            blocks.append("""
            次の誤認識は、矢印の右の表記へ直してください。
            \(corrections.joined(separator: "\n"))
            """)
        }

        blocks.append("""
        整形対象:
        \(rawText)
        """)

        return blocks.joined(separator: "\n\n")
    }
}
