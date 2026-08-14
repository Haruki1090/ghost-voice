import Foundation

public protocol Refining: Sendable {
    /// LLM が使えるか。Apple Intelligence が無効な環境では false。
    var isAvailable: Bool { get }

    /// モデルを事前ロードする。起動時に一度呼ぶ。
    func prewarm() async

    /// 整形する。タイムアウトまたは失敗時は nil を返し、呼び出し側が生テキストへ縮退する。
    ///
    /// **`timeout` は実時間の上限として守られる。** 打ち切った生成の完了は待たない。
    /// ただし打ち切った生成はデーモン側で走り続けうる（cancel は送るが応答は保証されない）。
    func refine(
        _ raw: String, locale: Locale, terms: [VocabularyTerm], timeout: Duration
    ) async -> String?
}

/// テスト用。指定した遅延の後に指定した結果を返す。
public struct StubRefiner: Refining {
    private let result: String?
    private let delay: Duration

    public init(result: String?, delay: Duration) {
        self.result = result
        self.delay = delay
    }

    public var isAvailable: Bool { result != nil }

    public func prewarm() async {}

    public func refine(
        _ raw: String, locale: Locale, terms: [VocabularyTerm], timeout: Duration
    ) async -> String? {
        guard let result, RefinementGuard.isRefinable(raw) else { return nil }
        return await withTimeout(timeout) { [delay] in
            try? await Task.sleep(for: delay)
            return Task.isCancelled ? nil : result
        }
    }
}

/// 整形として受け入れてよい入力・出力かの判定。
///
/// 整形の中身は LLM に委ねるしかないが、「整形と呼べる形をしているか」だけは
/// 手元で判定できる。ここを通らなかった出力は捨てて生テキストへ縮退する。
enum RefinementGuard {

    /// 整形しても意味の無い入力を弾く。空白だけの認識結果に LLM を回すと、
    /// 何も得ないまま挿入がタイムアウトぶん遅れる。
    static func isRefinable(_ raw: String) -> Bool {
        !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 出力が `raw` の整形結果として妥当な長さに収まっているか。
    ///
    /// 整形は「フィラーを削り、言い直しを畳み、句読点を補う」操作なので、出力が入力より
    /// 大きく伸びることはない。実測（12 発話・新規セッション・temperature 0）でも
    /// 出力 / 入力 は最大 1.00、増分は最大 0 字だった。
    ///
    /// 一方、発話が命令文に読めるとモデルは整形ではなく**その依頼への回答**を返す。
    /// 実測では 5 発話中 4 発話が再現性 100 % で逸脱し、出力は入力の 2.6〜25.6 倍
    /// （+39〜+639 字）へ膨らんで Python のコード片や手順書が混ざった。
    /// 逸脱の多くは生成に 1.3〜3.4 秒掛かってタイムアウトで落ちるが、実測 0.505 秒の
    /// 例があり、既定のタイムアウト（750 ms）をすり抜けてユーザーのテキスト欄へ入りうる。
    /// **逸脱を止めるのはタイムアウトではなくこの検査である。**
    ///
    /// 句読点の補完と正規表記への置換（例: ジーエイエス → Google Apps Script）で
    /// 多少は伸びるため、比だけでなく短文向けの下駄も併せて許容量を決める。
    static func isPlausible(_ output: String, refinementOf raw: String) -> Bool {
        output.count <= max(raw.count * 3 / 2, raw.count + shortInputAllowance)
    }

    /// 短い入力で比が跳ねるぶんの下駄。「はい」→「はい。」を落とさないために要る。
    private static let shortInputAllowance = 16

    /// 整形された発話にコードフェンスは現れない。現れたらそれは整形ではなく、
    /// 依頼を実行した結果のコード片である。
    ///
    /// 長さの検査と別に要る。`isPlausible` は長さしか見ないので、入力と同程度の
    /// 短いコード片（30 字の発話に対する 40 字のコード片は比 1.33）が素通りする。
    static func containsCodeFence(_ output: String) -> Bool {
        output.contains("```")
    }

    /// 出力が入力の**変換**になっているか。**入力に無い語がどれだけ足されたか**で測る。
    ///
    /// **長さとコードフェンスだけでは、入力と同じくらいの長さの逸脱を止められない**
    /// （実機で観測 / 2026-08-14。要件定義書 §2.8.5）:
    ///
    /// ```
    /// raw    : 東京の天気どんな感じですか？   （14 字）
    /// refined: 東京の天気は晴れています。     （13 字。比 0.93 で `isPlausible` を通る）
    /// ```
    ///
    /// **モデルが質問に答え、その答えが利用者の発話として挿入された。** 内容は作り話で
    /// ある（モデルは天気を知らない）。テキストを失うより重い——言っていないことを
    /// 言ったことにしている。
    ///
    /// ## フェーズ 1 の指標が誤っていた（V-37 / 実測 2026-08-15）
    ///
    /// 最初の指標は「共通部分列 / **短い方**の長さ」だった。これは
    /// **max(入力の残存率, 出力の由来率)** に等しく、**2 方向の甘い方**を採る。
    /// 結果、**入力が丸ごと残っていれば追加は何字あっても 1.000** になる——
    /// **追加に対して原理的に盲目**だった。
    ///
    /// 実機で実際に起きていたこと（`say -v Kyoko` のフィクスチャ 6 秒スライス）:
    ///
    /// ```
    /// raw    : 本日は…まず前回のミーティングの振替                    （36 字）
    /// refined: 本日は…まず前回のミーティングの振替についてお話しします。（47 字）
    /// ```
    ///
    /// **「についてお話しします」は誰も言っていない。** 旧指標は 1.000 を返し、
    /// 長さの検査も通り、**利用者の欄へ入っていた。**
    /// 10 秒スライス（56 字 → 96 字。40 字ぶんの会議報告が丸ごと作り話）が捨てられたのは、
    /// 指標が捕まえたからではなく**長さの上限に偶然引っ掛かった**だけである。
    ///
    /// ## 発話長への依存は「逆向き」だった
    ///
    /// V-37 の当初の疑いは「長い発話ほど比が下がって正当な整形が落ちる」だったが、
    /// **実測は逆**で、旧指標は長いほど**上がった**（19 字 0.933 → 124 字 0.991。
    /// フィラーが長文では相対的に小さくなるため）。
    /// **5〜124 字の 9 例すべてで正当な整形は受け入れられていた。**
    /// A4 が観測した「56 字が 10/10 捨てられる」は発話長の問題ではなく、
    /// **音声を 10 秒で切ったために発話が文の途中で終わっていた**ことによる。
    ///
    /// ## 残存率の向きは閾値で分けられない（判定に使わない理由）
    ///
    /// | 操作 | 例 | 残存率 |
    /// |---|---|---|
    /// | フィラー削除（短文） | `えー、はい` → `はい。` | **0.400** |
    /// | フィラー削除（中） | `あのー、会議は、えっと明日です` → `会議は明日です。` | 0.467 |
    /// | **逸脱（回答）** | `東京の天気どんな感じですか？` → `東京の天気は晴れています。` | **0.429** |
    ///
    /// **0.400 と 0.429 は分けられない。** フィラー削除は「消す」操作で、
    /// 短い発話ほど消える割合が大きい。**分かれるのは消した量ではなく足した量である。**
    /// `coverageRatio` は計測のために残してあるが、判定には使わない。
    ///
    /// ## 用語の正規化（FR-6）を逸脱と分ける工夫は残してある
    ///
    /// `ジーエイエスを使いました` → `Google Apps Script を使いました。` は、
    /// 素で測ると **16 字の追加**（逸脱の最小 5 字を大きく超える）。
    /// だから `accept` は**先に頼んだ置換を入力へ当ててから**測る
    /// （`applyingVocabulary(_:terms:)`）。当てた後は追加 0 字になる。
    /// **辞書を渡さなければ同じ出力が落ちる**ことも検査で固定してある。
    ///
    /// 共通部分列の長さ。1 行ぶんだけ持って回す。
    static func commonSubsequenceLength(_ a: [Character], _ b: [Character]) -> Int {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var previous = [Int](repeating: 0, count: b.count + 1)
        var current = previous
        for i in 1...a.count {
            for j in 1...b.count {
                current[j] = a[i - 1] == b[j - 1] ? previous[j - 1] + 1 : max(previous[j], current[j - 1])
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }

    /// 入力のどれだけが出力に残ったか。**言われたことが消えていないか**を見る。
    /// **判定には使わない**（`unsupportedAdditions` の doc にある実測のとおり、
    /// この向きは正当な整形と逸脱を分けられない）。計測と報告のために置いてある。
    static func coverageRatio(_ output: String, of expected: String) -> Double {
        let a = Array(expected), b = Array(output)
        guard !a.isEmpty else { return 0 }
        return Double(commonSubsequenceLength(a, b)) / Double(a.count)
    }

    /// 出力のうち、**入力にも句読点にも由来しない文字の数**。
    ///
    /// 判定はこの 1 つで行う。詳細は `maximumUnsupportedAdditions`。
    static func unsupportedAdditions(_ output: String, of expected: String) -> Int {
        let a = withoutFreelyInsertable(expected)
        let b = withoutFreelyInsertable(output)
        guard !b.isEmpty else { return 0 }
        return b.count - commonSubsequenceLength(a, b)
    }

    /// **整形が自由に足してよい文字**——句読点と空白。
    ///
    /// 整形の仕事の一つは「句読点を適切に補う」ことなので、句読点の追加は勘定に入れない。
    /// 入れると**節の多い長い発話ほど落ちる**指標になり、V-37 が疑った長さ依存を
    /// 直した側で作り込むことになる（実測: 句読点の少ない 49 字の発話で読点 2 + 句点 1）。
    private static func withoutFreelyInsertable(_ text: String) -> [Character] {
        text.filter { character in
            !character.unicodeScalars.allSatisfy(freelyInsertable.contains)
        }
    }

    private static let freelyInsertable = CharacterSet.whitespacesAndNewlines
        .union(.punctuationCharacters)

    /// 入力に無い語の許容量。**句読点・空白は数に入らない**ので、これは
    /// 「利用者が言っていない語をどれだけ通すか」そのものである。
    ///
    /// 実測（2026-08-15 / MacBook Pro M3 / macOS 26.5.2 / temperature 0 / 各 3 回同一）:
    ///
    /// | 種別 | 例 | 追加字数 |
    /// |---|---|---|
    /// | フィラー削除・句読点補完（5〜124 字の 11 例） | `えーっと、あの、来週までに…` → `来週までに…。` | **0** |
    /// | 数量表記の正規化 | `…は十時から…` → `…は10時から…。` | **2** |
    /// | **逸脱: 質問への回答** | `東京の天気どんな感じですか？` → `東京の天気は晴れています。` | **6** |
    /// | **逸脱: 無関係な応答** | `おはようございます` → `承知しました。` | **5** |
    /// | **逸脱: 続きの捏造** | `…振り返りから始めさせてください。前回は新しい` → `…新しいプロジェクトの進捗を確認し、…強化しました。` | **38** |
    ///
    /// 正当な整形の最大は 2、逸脱の最小は 5。**境界は 3 に置いてある**——
    /// 観測した正当側に 1 字、逸脱側に 2 字の余裕がある。
    ///
    /// - Note: **この量は発話長に依存しない。** 句読点を勘定から外したことで、
    ///   長い発話ほど不利になる項が消えている（V-37 の再発防止）。
    ///   閾値ではなく指標を疑うべき報告——**正当な整形が落ちる、あるいは
    ///   捏造が通る**——が出たら、まず「何字足されたか」を実測して表へ足すこと。
    static let maximumUnsupportedAdditions = 3

    /// 頼んだ置換（FR-6 の用語辞書）を入力へ先に当てる。
    ///
    /// **これをしないと、用語の正規化が逸脱と区別できない。**
    /// `ジーエイエスを使いました` → `Google Apps Script を使いました。` は素で測ると
    /// **16 字の追加**で、逸脱の最小（5 字）を大きく超える（上記の表）。
    /// 整形器はこの辞書をプロンプトへ入れて置換を依頼しているので、
    /// **置換後の姿こそが「期待される入力」である。**
    static func applyingVocabulary(_ raw: String, terms: [VocabularyTerm]) -> String {
        var result = raw
        for term in terms {
            for variant in term.misheard where !variant.isEmpty {
                result = result.replacingOccurrences(of: variant, with: term.canonical)
            }
        }
        return result
    }

    /// LLM の出力を整形結果として受け入れるか決める。受け入れないときは nil を返し、
    /// 呼び出し側が生テキストへ縮退する。
    static func accept(
        _ output: String, refinementOf raw: String, terms: [VocabularyTerm] = []
    ) -> String? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        // 追加字数は**頼んだ置換を当てた後の入力**と比べる（`applyingVocabulary` の理由）。
        let expected = applyingVocabulary(raw, terms: terms)
        // 長さの検査を先に通す。`unsupportedAdditions` は共通部分列を取るので
        // 出力の長さに比例して重くなり、暴走した生成をそのまま渡したくない。
        guard !trimmed.isEmpty,
              !containsCodeFence(trimmed),
              isPlausible(trimmed, refinementOf: raw),
              unsupportedAdditions(trimmed, of: expected) <= maximumUnsupportedAdditions
        else { return nil }
        return trimmed
    }
}

/// 指定時間内に完了しなければ nil を返す。**打ち切った作業の完了は待たない。**
///
/// `withTaskGroup` はスコープを抜ける際に子タスクの完了を待つ。その形で書くと、
/// 作業が打ち切りに応じない場合に呼び出しの実時間が `timeout` を超え、
/// **ユーザーへの文字入力がその間ずっと止まる。**
/// 実測（キャンセルを尊重しない 2 秒の作業を 50ms で打ち切る）:
/// 待つ実装 2.132 秒 / 待たない実装 0.059 秒。
///
/// `FoundationModels` の `respond` は実際にはキャンセルに応じる（暴走した生成を
/// 500ms で打ち切っても 0.529 秒で返った）が、**そこに依存しない形にしてある。**
/// 打ち切った生成はデーモン側で走り続けうる。挿入が止まるよりはましと判断した。
///
/// 打ち切った生成が次の発話と衝突して `concurrentRequests` になることは無い。
/// セッションはリクエストごとに作られ、次の発話は別のセッションを使う。
func withTimeout(_ timeout: Duration, _ work: @escaping @Sendable () async -> String?) async -> String? {
    let stream = AsyncStream<String?>.makeStream()

    let workTask = Task {
        stream.continuation.yield(await work())
        stream.continuation.finish()
    }
    let timeoutTask = Task {
        try? await Task.sleep(for: timeout)
        stream.continuation.yield(nil)
        stream.continuation.finish()
    }
    // 待ちはしないが cancel は送る。止められる作業なら止めて計算資源を返す。
    defer {
        workTask.cancel()
        timeoutTask.cancel()
    }

    var results = stream.stream.makeAsyncIterator()
    return await results.next() ?? nil
}
