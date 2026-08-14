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

    /// 出力が入力の**変換**になっているか。共通部分列の長さで測る。
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
    /// 既存の 2 つの検査が見ているのは「大きさ」と「1 つの目印」だけで、
    /// **出力が入力の変換であるかを一度も確かめていなかった。** ここがその検査である。
    ///
    /// 割る数を**短い方の長さ**にしてあるのが要点。フィラー削除（入力が縮む）と
    /// 句読点の補完（出力が伸びる）の両方を通すためである。
    ///
    /// **用語の正規化（FR-6）は、この指標だけでは逸脱と区別できない。** 実測:
    ///
    /// | 操作 | 例 | 残存率 |
    /// |---|---|---|
    /// | 句読点 | `はい` → `はい。` | 1.00 |
    /// | フィラー削除 | `あのー、会議は、えっと明日です` → `会議は明日です。` | 0.88 |
    /// | **用語の正規化** | `ジーエイエスを使いました` → `Google Apps Script を使いました。` | **0.50** |
    /// | **逸脱（回答）** | `東京の天気どんな感じですか？` → `東京の天気は晴れています。` | **0.46** |
    /// | 無関係 | `おはようございます` → `承知しました。` | 0.14 |
    ///
    /// **0.50 と 0.46 は閾値で分けられない。** どちらも「入力の文字を大きく置き換える」
    /// 操作だからである。違いは**片方は我々が頼んだ置換で、もう片方は頼んでいない**
    /// という一点にある。だから `accept` は**先に頼んだ置換を適用してから**ここへ渡す
    /// （`applyingVocabulary(_:terms:)`）。適用後は用語の正規化がほぼ恒等変換になり、
    /// 逸脱だけが低いまま残る。
    ///
    /// - Note: **観測点はまだ少ない**（逸脱 2 例・正当 5 例）。境界は 0.6 に置いてあるが、
    ///   正当な整形を落とす報告が出たら、**閾値ではなく指標そのものを見直すこと。**
    ///   最初に書いた「用語の正規化は約 0.79 だから通る」という見積もりは**外れていた**
    ///   （実測 0.50）。検査が先に潰した。
    static func retainedRatio(_ output: String, refinementOf raw: String) -> Double {
        let a = Array(raw), b = Array(output)
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        // 共通部分列の長さ。1 行ぶんだけ持って回す。
        var previous = [Int](repeating: 0, count: b.count + 1)
        var current = previous
        for i in 1...a.count {
            for j in 1...b.count {
                current[j] = a[i - 1] == b[j - 1] ? previous[j - 1] + 1 : max(previous[j], current[j - 1])
            }
            swap(&previous, &current)
        }
        return Double(previous[b.count]) / Double(min(a.count, b.count))
    }

    /// 残存率の下限。詳細は `retainedRatio(_:refinementOf:)`。
    static let minimumRetainedRatio = 0.6

    /// 頼んだ置換（FR-6 の用語辞書）を入力へ先に当てる。
    ///
    /// **これをしないと、用語の正規化と逸脱が残存率で区別できない**（上記の表）。
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
        // 残存率は**頼んだ置換を当てた後の入力**と比べる（`applyingVocabulary` の理由）。
        let expected = applyingVocabulary(raw, terms: terms)
        guard !trimmed.isEmpty,
              !containsCodeFence(trimmed),
              isPlausible(trimmed, refinementOf: raw),
              retainedRatio(trimmed, refinementOf: expected) >= minimumRetainedRatio
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
