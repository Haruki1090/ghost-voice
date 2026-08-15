import Foundation
import Testing

@testable import GhostVoiceCore

/// **V-37 の切り分け計測。** `RefinementGuard` が発話長に対してどう振る舞うかを実測する。
///
/// トラック A4 の実測で「56 字の発話は、整形が締め切り内に完了しているのに
/// `RefinementGuard` が 10/10 捨てた」ことが判った。**打ち切りでは解けない。**
/// ここは「何が捨てているのか」を、捨てる前の出力ごと表に出す。
///
/// **結論（2026-08-15）**: **発話長は原因ではなかった**（言い終えた 5〜124 字の 9 例は
/// すべて受け入れられている）。A4 の 56 字は**音声を 10 秒で切って文の途中にした**もので、
/// **モデルが 40 字ぶんを捏造していた**（`reproducesA4Slices`）。捨てたのは正しい。
/// **代わりに、旧指標が「足された語」に盲目である**ことがここで判り、指標を作り直した
/// （要件定義書 §2.8.7 / 詳細設計書 §5.5.1）。
///
/// ## 何を通しているか
///
/// | 部品 | 本物か |
/// |---|---|
/// | 整形（`FoundationModelRefiner.generate`） | **本物。** Apple Intelligence を実際に回す |
/// | 認識 | `reproducesA4Slices` だけ**本物**（フィクスチャ音声）。他は台本のテキスト |
/// | マイク | **開かない** |
/// | 挿入先 | **触れない**（判定しか見ない） |
///
/// ## 既定の `swift test` では走らない
///
/// 実 LLM を数十回回すので数分掛かり、機体を飽和させる。
/// `GHOST_VOICE_E_MEASURE=1` を付けたときだけ走る
/// （**禁じられた 3 つの環境変数は使っていない**）。
@Suite(
    "E: RefinementGuard の指標が発話長に対してどう振る舞うか",
    .serialized,
    .enabled("GHOST_VOICE_E_MEASURE=1 を付けると実行される") {
        ProcessInfo.processInfo.environment["GHOST_VOICE_E_MEASURE"] == "1"
    },
    .enabled(if: FoundationModelRefiner().isAvailable, "Apple Intelligence が要る")
)
struct RefinementGuardMeasurement {

    /// 発話長の階段。**A4 が捨てられた 56 字帯を挟む形で取る。**
    /// 内容は会議・作業報告という同じ領域に揃えてある（話題で結果が変わる分を抑えるため）。
    /// **どれも文として終わっている**（言い終えてから PTT を離した場合に当たる）。
    static let completeUtterances: [String] = [
        "えー、はい",
        "あの、了解です",
        "えーっと、明日は十時に集合してください",
        "えーっと、あの、来週までに要件定義を完了させます",
        "その、次のミーティングは水曜日の午後三時からでお願いします",
        "えー、この件は田中さんに引き継ぎましたので、あの、確認をお願いします",
        "えーっと、本日はお時間をいただきありがとうございます。まず前回のミーティングの振り返りから、あの、始めさせてください",
        "えー、現状の課題としては、外部のクラウドサービスに音声データを送信することへのセキュリティ上の懸念、あの、および従量課金によるコストの増大が挙げられます",
        "その、技術的には、アップルが提供する新しい音声認識のフレームワークを利用することで、えーっと、ネットワーク接続なしに、高速かつ高精度な文字起こしが実現できる見込みです。処理速度については、一時間の会議音声を数分程度で処理できることを目標としています",
    ]

    /// **文の途中で切れた発話。** A4 の 56 字はこれだった——フィクスチャ音声を 10 秒で
    /// 打ち切っており、認識結果が語の途中で終わっている。
    ///
    /// **これは計測の都合ではなく実運用そのものである。** PTT は利用者が離した瞬間に
    /// 確定するので、**言い終える前に離せば必ずこの形になる。**
    static let truncatedUtterances: [String] = [
        "えーっと、明日の会議なんですけど",
        "本日はお時間をいただきありがとうございます。まず前回のミーティングの振替",
        "えー、現状の課題としては、外部のクラウドサービスに音声データを送信することへのセキュリティ上の",
        "本日はお時間をいただきありがとうございます。まず前回のミーティングの振り返りから始めさせてください。前回は新しい",
    ]

    /// **句読点の少ない入力**と**数量表現**。許容量の根拠になる観測点。
    static let punctuationPoor: [String] = [
        "えー明日の会議は十時からですのでよろしくお願いします",
        "あの先月の実績は目標を少し下回りましたが今月は挽回できる見込みですので引き続きよろしくお願いします",
        "えーっと今日の売上は前年比で百二十パーセントでした",
        "その資料は明日までに送りますので確認をお願いしますまた不明点があれば連絡してください",
    ]

    static let repeats = 3

    @Test("発話長ごとに、捨てる前の出力と検査の内訳を出す")
    func measuresByLength() async {
        let refiner = FoundationModelRefiner()
        await refiner.prewarm()

        var rows: [String] = []
        for (label, inputs) in [
            ("言い終えた", Self.completeUtterances),
            ("**途中で切れた**", Self.truncatedUtterances),
            ("句読点が少ない", Self.punctuationPoor),
        ] {
            for raw in inputs {
                for pass in 1...Self.repeats {
                    let output = await refiner.generate(
                        prompt: RefinementPrompt.prompt(rawText: raw, terms: []),
                        locale: .jaJP,
                        timeout: .seconds(30)
                    )
                    guard let output else {
                        rows.append("| \(label) | \(raw.count) | \(pass) | **生成失敗** | - | - | - | - |")
                        continue
                    }
                    let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
                    let verdict = GuardVerdict(output: trimmed, raw: raw)
                    print("--- \(label) / 入力 \(raw.count) 字 / \(pass) 回目 ---")
                    print("  raw: \(raw)")
                    print("  out: \(trimmed)")
                    print("  \(verdict.line)")
                    rows.append("| \(label) | \(raw.count) | \(pass) | \(verdict.row) |")
                }
            }
        }

        print("=== V-37 計測表（実 LLM） ===")
        print("| 種別 | 入力字数 | 回 | 出力字数 | isPlausible | 旧 retainedRatio | 残存率 | **追加字数** | accept |")
        print("|---|---|---|---|---|---|---|---|---|")
        for row in rows { print(row) }
    }

    /// 実 LLM を回さずに、**指標そのもの**を既知の事例へ当てて並べる。
    @Test("既知の事例に対する指標の値を並べる")
    func measuresKnownCases() {
        let cases: [(String, String, String, [VocabularyTerm])] = [
            ("句読点のみ", "はい", "はい。", []),
            ("フィラー削除（短）", "えー、こんにちは", "こんにちは。", []),
            ("フィラー削除（中）", "あのー、会議は、えっと明日です", "会議は明日です。", []),
            ("用語の正規化", "ジーエイエスを使いました", "Google Apps Script を使いました。",
             [VocabularyTerm(canonical: "Google Apps Script", misheard: ["ジーエイエス"])]),
            ("用語の正規化（辞書なし）", "ジーエイエスを使いました", "Google Apps Script を使いました。", []),
            ("**逸脱: 回答1**", "東京の天気どんな感じですか？", "東京の天気は晴れています。", []),
            ("**逸脱: 回答2**", "明日の天気って何でしょうか？", "明日の天気は晴れそうです。", []),
            ("**逸脱: 無関係**", "おはようございます", "承知しました。", []),
            ("**逸脱: 続きの捏造（実測 96 字）**",
             "本日はお時間をいただきありがとうございます。まず前回のミーティングの振り返りから始めさせてください。前回は新しい",
             "本日はお時間をいただきありがとうございます。まず前回のミーティングの振り返りから始めさせてください。前回は新しいプロジェクトの進捗を確認し、チームメンバーとのコミュニケーションを強化しました。",
             []),
            ("**逸脱: 続きの捏造（短い上乗せ）**",
             "本日はお時間をいただきありがとうございます。まず前回のミーティングの振り返りから始めさせてください。前回は、新し",
             "本日はお時間をいただきありがとうございます。まず前回のミーティングの振り返りから始めさせてください。前回は、新しい体制について話し合いました。",
             []),
        ]

        print("=== 既知の事例に対する指標の値 ===")
        print("| 事例 | 入力字数 | 出力字数 | isPlausible | 旧 retainedRatio | 残存率 | **追加字数** | accept |")
        print("|---|---|---|---|---|---|---|---|")
        for (label, raw, output, terms) in cases {
            let verdict = GuardVerdict(output: output, raw: raw, terms: terms)
            print("| \(label) | \(raw.count) | \(verdict.row) |")
        }
    }

    /// **A4 が観測した 56 字そのものを再現する。**
    ///
    /// A4 は `say -v Kyoko` のフィクスチャを 3 / 6 / 10 秒で切って流した。
    /// **10 秒の切り口がどこに落ちるかは原稿の読み上げ速度で決まる**ので、
    /// 認識結果を推測してはならない。ここで実際に取る。
    @Test(
        "A4 の 3 / 6 / 10 秒スライスの認識結果と整形の顛末",
        .enabled("音声フィクスチャが要る（cd Tests/Fixtures && say -v Kyoko -f jp-meeting.txt -o jp-meeting.aiff）") {
            SpeechFixtures.audioExists
        },
        .enabled("ja-JP のモデル資産が要る") { await SpeechFixtures.modelInstalled(locale: .jaJP) }
    )
    func reproducesA4Slices() async throws {
        let refiner = FoundationModelRefiner()
        await refiner.prewarm()

        for seconds in [3.0, 6.0, 10.0] {
            let transcriber = SpeechAnalyzerTranscriber()
            try await transcriber.prepare(locale: .jaJP, kind: Settings.default.transcriberKind)
            let format = try #require(await transcriber.requiredAudioFormat)
            let buffers = try SpeechFixtures.buffers(
                from: SpeechFixtures.audioURL, to: format, limitSeconds: seconds)

            let stream = try await transcriber.begin()
            for buffer in buffers { await transcriber.feed(SpeechFixtures.detachedCopy(of: buffer)) }
            try await transcriber.finish()

            var raw = ""
            for try await update in stream {
                if case .final(let text) = update { raw += text }
            }

            print("=== \(seconds) 秒スライス ===")
            print("  raw(\(raw.count) 字): \(raw)")
            guard !raw.isEmpty else { continue }

            for pass in 1...Self.repeats {
                let output = await refiner.generate(
                    prompt: RefinementPrompt.prompt(rawText: raw, terms: []),
                    locale: .jaJP,
                    timeout: .seconds(30)
                )
                guard let output else { print("  \(pass): **生成失敗**"); continue }
                let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
                print("  \(pass) out(\(trimmed.count) 字): \(trimmed)")
                print("    " + GuardVerdict(output: trimmed, raw: raw).line)
            }
        }
    }
}

/// 1 件ぶんの判定内訳。**旧指標も併記する**——直す前と後を同じ表で見るために要る。
struct GuardVerdict {
    let outputLength: Int
    let plausible: Bool
    let legacyRetained: Double
    let coverage: Double
    let additions: Int
    let accepted: Bool

    init(output: String, raw: String, terms: [VocabularyTerm] = []) {
        let expected = RefinementGuard.applyingVocabulary(raw, terms: terms)
        outputLength = output.count
        plausible = RefinementGuard.isPlausible(output, refinementOf: raw)
        legacyRetained = Self.legacyRetainedRatio(output, of: expected)
        coverage = RefinementGuard.coverageRatio(output, of: expected)
        additions = RefinementGuard.unsupportedAdditions(output, of: expected)
        accepted = RefinementGuard.accept(output, refinementOf: raw, terms: terms) != nil
    }

    /// **フェーズ 1 の指標**（共通部分列 / 短い方の長さ）。実装からは外したが、
    /// 「何が変わったか」を数字で示すために計測側へ写してある。
    static func legacyRetainedRatio(_ output: String, of expected: String) -> Double {
        let a = Array(expected), b = Array(output)
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        let lcs = RefinementGuard.commonSubsequenceLength(a, b)
        return Double(lcs) / Double(min(a.count, b.count))
    }

    var row: String {
        let legacy = String(format: "%.3f", legacyRetained)
        let covered = String(format: "%.3f", coverage)
        return "\(outputLength) | \(plausible) | \(legacy) | \(covered) | **\(additions)** | \(accepted)"
    }

    var line: String {
        "出力 \(outputLength) 字 / plausible=\(plausible) 旧retained=\(String(format: "%.3f", legacyRetained))"
        + " 残存=\(String(format: "%.3f", coverage)) 追加=\(additions) accepted=\(accepted)"
    }
}
