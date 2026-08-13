import Foundation

public protocol Refining: Sendable {
    /// LLM が使えるか。Apple Intelligence が無効な環境では false。
    var isAvailable: Bool { get }

    /// モデルを事前ロードする。起動時に一度呼ぶ。
    func prewarm() async

    /// 整形する。タイムアウトまたは失敗時は nil を返し、呼び出し側が生テキストへ縮退する。
    ///
    /// 発話 1 件につき 1 回、直列に呼ぶ前提（PTT は同時に 2 発話を持たない）。
    /// 同時に呼ぶと `LanguageModelSession` が `concurrentRequests` を投げ、
    /// 後から入った方が nil になる（生テキストへ縮退するので壊れはしない）。
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

    /// LLM の出力を整形結果として受け入れるか決める。受け入れないときは nil を返し、
    /// 呼び出し側が生テキストへ縮退する。
    static func accept(_ output: String, refinementOf raw: String) -> String? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, isPlausible(trimmed, refinementOf: raw) else { return nil }
        return trimmed
    }
}

/// 指定時間内に完了しなければ nil を返す。
///
/// 打ち切り後も `work` の完了を待ってから返る。`LanguageModelSession` は前の応答が
/// 終わる前に呼び直すと `concurrentRequests` を投げるため、打ち切った生成を
/// 放置したまま次の発話へ進むとセッションが詰まる。
func withTimeout(_ timeout: Duration, _ work: @escaping @Sendable () async -> String?) async -> String? {
    await withTaskGroup(of: String?.self) { group in
        group.addTask { await work() }
        group.addTask {
            try? await Task.sleep(for: timeout)
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}
