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

    /// 句読点・空白の差は精度の本質ではないため除去して比較する。
    private static func normalize(_ text: String) -> String {
        text.filter { !$0.isWhitespace && !$0.isPunctuation }
    }
}
