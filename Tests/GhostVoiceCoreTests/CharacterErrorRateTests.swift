import Testing
import Foundation

/// CER はゴールデンテストの合否そのものを決める物差しである。
/// 物差しが狂っていれば認識精度の閾値判定は無意味になるため、
/// 既知の入力に対する期待値をここで固定する。
@Suite("CharacterErrorRate")
struct CharacterErrorRateTests {

    // MARK: - 基本

    @Test("完全一致は 0")
    func identicalIsZero() {
        #expect(CharacterErrorRate.compute(reference: "音声認識", hypothesis: "音声認識") == 0)
    }

    /// 分母は参照文字列の長さ。仮説の長さで割ると 1/2 になり、
    /// 「短く出力するほど CER が下がる」という逆向きの誘因が生まれる。
    @Test("置換 1 文字は 1 / 参照長")
    func substitutionCountsOnce() {
        // 参照 4 文字のうち 2 文字を置換 → 0.5
        #expect(CharacterErrorRate.compute(reference: "音声認識", hypothesis: "音声任期") == 0.5)
        // 参照 3 文字・仮説 3 文字で 1 置換 → 1/3
        #expect(abs(CharacterErrorRate.compute(reference: "abc", hypothesis: "abd") - 1.0 / 3.0) < 1e-12)
    }

    /// 参照長と仮説長が違う例を使う。分母を hyp.count に取り違えると
    /// 1/2 になって落ちる。
    @Test("欠落 1 文字は 1 / 参照長")
    func deletionCountsOnce() {
        #expect(abs(CharacterErrorRate.compute(reference: "abc", hypothesis: "ac") - 1.0 / 3.0) < 1e-12)
    }

    @Test("挿入 1 文字は 1 / 参照長")
    func insertionCountsOnce() {
        #expect(abs(CharacterErrorRate.compute(reference: "abc", hypothesis: "abxc") - 1.0 / 3.0) < 1e-12)
    }

    /// レーベンシュタイン距離の教科書例。3 操作（k→s, e→i, +g）で 6 文字中 3 → 0.5。
    /// 置換・挿入・欠落のどれか 1 種類でも経路から欠けるとこの値にならない。
    @Test("kitten → sitting は距離 3")
    func classicLevenshteinExample() {
        #expect(CharacterErrorRate.compute(reference: "kitten", hypothesis: "sitting") == 0.5)
    }

    /// 連続した欠落を 1 回ぶんに丸めないこと。
    @Test("連続した欠落は文字数ぶん数える")
    func consecutiveDeletionsAccumulate() {
        // 参照 10 文字から 4 文字ぶんの句を落とす → 0.4
        #expect(CharacterErrorRate.compute(reference: "あいうえおかきくけこ", hypothesis: "あいうえおこ") == 0.4)
    }

    /// PTT ではキー押下が発話に間に合わず、頭が丸ごと落ちることがある。
    /// DP の行頭コストを距離 i でなく 0 にすると参照の先頭を無料で捨てられてしまい、
    /// この最も起こりやすい誤りを 0 と評価してしまう。
    @Test("先頭がまるごと欠けた場合も欠落として数える")
    func leadingDeletionCounts() {
        #expect(CharacterErrorRate.compute(reference: "あいうえおかきくけこ", hypothesis: "かきくけこ") == 0.5)
    }

    @Test("末尾がまるごと欠けた場合も欠落として数える")
    func trailingDeletionCounts() {
        #expect(CharacterErrorRate.compute(reference: "あいうえおかきくけこ", hypothesis: "あいうえお") == 0.5)
    }

    // MARK: - 端

    @Test("参照も仮説も空なら 0")
    func bothEmptyIsZero() {
        #expect(CharacterErrorRate.compute(reference: "", hypothesis: "") == 0)
    }

    @Test("参照が空で仮説があれば 1")
    func emptyReferenceWithHypothesisIsOne() {
        #expect(CharacterErrorRate.compute(reference: "", hypothesis: "何か") == 1)
    }

    /// 認識が丸ごと失敗して空文字が返るのは実際に起こりうる。
    /// ここで異常終了すると、テストは「落ちた」ではなく「クラッシュした」になる。
    @Test("仮説が空なら全文字が欠落で 1")
    func emptyHypothesisIsOne() {
        #expect(CharacterErrorRate.compute(reference: "音声認識", hypothesis: "") == 1)
    }

    /// 参照より長く誤る場合、CER は 1 を超えうる。1.0 で頭打ちにしないこと。
    @Test("参照より大幅に長い誤りは 1 を超える")
    func canExceedOne() {
        #expect(CharacterErrorRate.compute(reference: "あ", hypothesis: "いうえお") == 4.0)
    }

    // MARK: - 正規化

    /// 句読点を無視するのは、認識器が付けた句読点が LLM 整形（FR-5）で
    /// 書き換えられ、製品の出力品質に効かないためである。
    ///
    /// **「句読点の差は精度の本質ではない」からではない。** 実測では句読点を
    /// 残すか除くかで 2 モジュールの優劣が逆転する（`CharacterErrorRate` の
    /// doc コメントと詳細設計書 §11.2）。無視してよい差ではなく、
    /// 「後段で直せる差」だからこの物差しの対象外にしている。
    @Test("句読点の差は無視する")
    func ignoresPunctuation() {
        #expect(CharacterErrorRate.compute(
            reference: "こんにちは、世界。", hypothesis: "こんにちは世界"
        ) == 0)
        // 疑問符・感嘆符・中黒も同様
        #expect(CharacterErrorRate.compute(
            reference: "ございますか。", hypothesis: "ございますか？"
        ) == 0)
    }

    @Test("空白・改行の差は無視する")
    func ignoresWhitespace() {
        #expect(CharacterErrorRate.compute(
            reference: "音声 認識\n", hypothesis: "音声認識"
        ) == 0)
    }

    /// 正規化は「無視してよい差」だけを消す。正規化が行き過ぎて
    /// 文字種まで潰すと、本物の誤りを見逃す物差しになる。
    @Test("正規化しても本物の誤りは残る")
    func normalizationDoesNotHideRealErrors() {
        // 「従量課金」→「重量課金」は実測された誤り。句読点を挟んでも検出できること。
        let cer = CharacterErrorRate.compute(
            reference: "従量課金による、コストの増大", hypothesis: "重量課金によるコストの増大"
        )
        #expect(abs(cer - 1.0 / 13.0) < 1e-12)
    }
}
