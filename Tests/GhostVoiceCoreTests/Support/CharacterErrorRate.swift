import Foundation

/// レーベンシュタイン距離に基づく文字誤り率。
/// 完全一致で判定すると OS 更新でモデルが変わるたびに壊れるため、閾値判定に使う。
enum CharacterErrorRate {

    /// 参照文字数に対する編集距離の比。1 を超えうる（仮説が参照より大幅に長い場合）。
    static func compute(reference: String, hypothesis: String) -> Double {
        let ref = Array(normalize(reference))
        let hyp = Array(normalize(hypothesis))
        guard !ref.isEmpty else { return hyp.isEmpty ? 0 : 1 }
        // 仮説が空なら全文字が欠落。以降の `1...hyp.count` が空範囲になるため先に返す。
        guard !hyp.isEmpty else { return 1 }

        var previous = Array(0...hyp.count)
        var current = [Int](repeating: 0, count: hyp.count + 1)

        for i in 1...ref.count {
            current[0] = i
            for j in 1...hyp.count {
                let cost = ref[i - 1] == hyp[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return Double(previous[hyp.count]) / Double(ref.count)
    }

    /// 句読点と空白を除去して比較する。
    ///
    /// **「句読点の差は精度の本質ではないから」ではない。** その理由は実測で否定された。
    /// 句読点を残して測ると優劣が逆転する（`DictationTranscriber` 5.85 % 対
    /// `SpeechTranscriber` 4.96 %。除去すると 3.02 % 対 3.21 %）。
    /// 句読点は結論を左右する要素であって、無視してよい差ではない。
    ///
    /// 除去する理由は、本アプリの経路が 認識 → LLM 整形（句読点を補う。FR-5）→ 挿入 であり、
    /// **認識器が付けた句読点は後段で書き換えられるため製品の出力品質に効かない**からである。
    /// この正規化のもとでの CER は「LLM が直せない誤り」を測っている。
    /// 詳細設計書 §11.2 と要件定義書 §2.5 に同じ根拠を記載してある。
    private static func normalize(_ text: String) -> String {
        text.filter { !$0.isWhitespace && !$0.isPunctuation }
    }
}
