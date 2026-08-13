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
    /// 例があり、既定の 500ms をすり抜けてユーザーのテキスト欄へ入りうる。
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

    /// LLM の出力を整形結果として受け入れるか決める。受け入れないときは nil を返し、
    /// 呼び出し側が生テキストへ縮退する。
    static func accept(_ output: String, refinementOf raw: String) -> String? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !containsCodeFence(trimmed),
              isPlausible(trimmed, refinementOf: raw)
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
