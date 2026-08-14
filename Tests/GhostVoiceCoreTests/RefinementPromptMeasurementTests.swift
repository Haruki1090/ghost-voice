import Foundation
import FoundationModels
import Testing

@testable import GhostVoiceCore

/// **V-37 の対策候補を実測で比べる。**
///
/// 実測（`RefinementGuardMeasurement`）で判ったのは次の 2 つ。
///
/// 1. 発話が**文の途中で切れている**と、モデルは整形ではなく**続きを捏造する**
///    （実測: 56 字 → 96 字。40 字ぶんの会議報告が丸ごと作り話）。
///    PTT は利用者が離した瞬間に確定するので、**言い終える前に離せば必ずこの形になる。**
/// 2. `RefinementGuard` の残存率は**追加に対して盲目**で、
///    36 字の捏造（+11 字）は今日そのまま利用者の欄へ入っている。
///
/// ここは 1 に対する**プロンプト側の対策**が効くかを測る。
/// 効いても効かなくても、2 の指標の直しは要る（プロンプトは寄与を減らすだけで消しはしない
/// ——`RefinementPrompt` の枠と同じ性質）。
///
/// `GHOST_VOICE_E_MEASURE=1` を付けたときだけ走る。
@Suite(
    "E: 続きの捏造に対するプロンプト側の対策",
    .serialized,
    .enabled("GHOST_VOICE_E_MEASURE=1 を付けると実行される") {
        ProcessInfo.processInfo.environment["GHOST_VOICE_E_MEASURE"] == "1"
    },
    .enabled(if: FoundationModelRefiner().isAvailable, "Apple Intelligence が要る")
)
struct RefinementPromptMeasurement {

    /// 本番の `FoundationModelRefiner.generate` と同じ形（1 リクエスト 1 セッション /
    /// temperature 0）。**指示文を差し替えて比べるためだけに**ここに置く。
    private func generate(instructions: String, prompt: String) async -> String? {
        let session = LanguageModelSession(instructions: instructions)
        session.prewarm()
        return await withTimeout(.seconds(30)) {
            try? await session.respond(to: prompt, options: GenerationOptions(temperature: 0.0))
                .content
        }
    }

    /// 現行の指示文へ 1 行足しただけの候補。
    ///
    /// **指示文を写経しない。** 実測当時は 5 規則を写して 6 番目を足していたが、
    /// その後 `RefinementPrompt` に規則 5（数字の表記を変えない）が入り、
    /// **写経した側が古い指示文になって「現行との差」を測れなくなった**
    /// （この実験の主張は「現行 + 1 行」であって「当時の指示文 + 1 行」ではない）。
    /// 現行から組み立てれば、規則が増えても差は 1 行のままになる。
    private static var withNoContinuationRule: String {
        RefinementPrompt.instructions(for: .jaJP)
            + "\n\(nextRuleNumber). 入力が文の途中で終わっていても、続きを補わない。入力に無い語を足さない"
    }

    /// 現行の指示文の最後の規則番号 + 1。
    private static var nextRuleNumber: Int {
        RefinementPrompt.instructions(for: .jaJP)
            .split(separator: "\n")
            .compactMap { line in Int(line.prefix(while: \.isNumber)) }
            .max().map { $0 + 1 } ?? 6
    }

    /// **文の途中で切れた発話。** 実際の認識結果（3 / 6 / 10 秒スライス）と手で作った例。
    static let truncated: [String] = [
        "本日はお時間をいただきありがとうござい",
        "本日はお時間をいただきありがとうございます。まず前回のミーティングの振替",
        "本日はお時間をいただきありがとうございます。まず前回のミーティングの振り返りから始めさせてください。前回は新しい",
        "えーっと、明日の会議なんですけど",
        "えー、現状の課題としては、外部のクラウドサービスに音声データを送信することへのセキュリティ上の",
    ]

    /// **言い終えた発話。** 対策で正常な整形が壊れていないことを同じ run で見る。
    static let complete: [String] = [
        "えーっと、あの、来週までに要件定義を完了させます",
        "えー、この件は田中さんに引き継ぎましたので、あの、確認をお願いします",
        "えーっと、本日はお時間をいただきありがとうございます。まず前回のミーティングの振り返りから、あの、始めさせてください",
        "その、技術的には、アップルが提供する新しい音声認識のフレームワークを利用することで、えーっと、ネットワーク接続なしに、高速かつ高精度な文字起こしが実現できる見込みです。処理速度については、一時間の会議音声を数分程度で処理できることを目標としています",
    ]

    /// **句読点の少ない入力**と**数量表現**。追加の許容量を決めるのに要る観測点。
    /// 「モデルが句読点をいくつ足すか」「三時 → 3 時 のような変換をするか」は
    /// **推測してはならない**（許容量の根拠そのものになる）。
    static let punctuationPoor: [String] = [
        "えー明日の会議は十時からですのでよろしくお願いします",
        "あの先月の実績は目標を少し下回りましたが今月は挽回できる見込みですので引き続きよろしくお願いします",
        "えーっと今日の売上は前年比で百二十パーセントでした",
        "その資料は明日までに送りますので確認をお願いしますまた不明点があれば連絡してください",
    ]

    static let repeats = 3

    @Test("規則 6（続きを補わない）が効くか / 正常な整形を壊さないか")
    func comparesInstructions() async {
        var rows: [String] = []
        for (kind, inputs) in [
            ("**途中で切れた**", Self.truncated),
            ("言い終えた", Self.complete),
            ("句読点が少ない", Self.punctuationPoor),
        ] {
            for raw in inputs {
                for (label, instructions) in [
                    ("現行", RefinementPrompt.instructions(for: .jaJP)),
                    ("規則6あり", Self.withNoContinuationRule),
                ] {
                    var outputs: Set<String> = []
                    var addedCounts: [Int] = []
                    var acceptedCount = 0
                    for _ in 1...Self.repeats {
                        let output = await generate(
                            instructions: instructions,
                            prompt: RefinementPrompt.prompt(rawText: raw, terms: []))
                        guard let output else { continue }
                        let trimmed = output.trimmingCharacters(
                            in: .whitespacesAndNewlines)
                        outputs.insert(trimmed)
                        let lcs = RefinementGuard.commonSubsequenceLength(
                            Array(raw), Array(trimmed))
                        addedCounts.append(trimmed.count - lcs)
                        if RefinementGuard.accept(trimmed, refinementOf: raw) != nil {
                            acceptedCount += 1
                        }
                    }
                    print("--- \(kind) / \(label) / 入力 \(raw.count) 字 ---")
                    print("  raw: \(raw)")
                    for output in outputs { print("  out(\(output.count) 字): \(output)") }
                    print("  追加字数: \(addedCounts) / 旧 accept: \(acceptedCount)/\(Self.repeats)")
                    let added = addedCounts.map(String.init).joined(separator: ", ")
                    rows.append(
                        "| \(kind) | \(label) | \(raw.count) | \(added)"
                        + " | \(acceptedCount)/\(Self.repeats) |")
                }
            }
        }
        print("=== 規則 6 の比較表 ===")
        print("| 種別 | 指示文 | 入力字数 | 追加字数（|出力|-LCS） | 旧 accept |")
        print("|---|---|---|---|---|")
        for row in rows { print(row) }
    }
}
