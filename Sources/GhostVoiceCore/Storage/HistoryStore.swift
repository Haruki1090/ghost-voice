import Foundation

public final class HistoryStore: @unchecked Sendable {
    /// 挿入から Undo を受け付ける時間。これを過ぎるとユーザーが手で
    /// 編集している可能性があるため、無効にする。
    public static let undoWindow: TimeInterval = 10

    private let file: AtomicJSONFile<[HistoryEntry]>
    private let limit: Int
    private let lock = NSLock()
    private var cached: [HistoryEntry]

    public init(rootURL: URL = StorageRoot.default, limit: Int) {
        // 復元できなかったファイルの退避は `file` 側が覚えていて `save` が行う。
        // ただし読み込みが前提なので、ここでの `load()` を遅延させないこと。
        self.file = AtomicJSONFile(
            url: rootURL.appendingPathComponent("history.json"),
            fallback: []
        )
        // 上限は人が手で編集する設定ファイル由来で、負数が来ても `Settings` は弾かない。
        // そのまま `removeLast` へ渡すと配列の要素数を超えて落ち、履歴を書く時点では
        // 発話がもう手元にしか無いので、発話ごと失う。
        //
        // 丸め先を 0 にしないのは、0 が「履歴を残さない」という別の指示だから。負数を
        // そこへ倒すと、打ち間違い 1 文字で履歴も Undo も挿入失敗時の退避先も無言で
        // 消える（`undoCandidate` は `entries.first` を見るので Undo は恒久的に死ぬ）。
        // 負数は `-1` を「無制限」と書いた可能性も含めて意図が読めないので、既定値で
        // 動かす。0 は明示的な指示として尊重する（要素数ぴったりの `removeLast` は
        // 落ちないので、クランプも要らない）。
        self.limit = limit < 0 ? Settings.default.historyLimit : limit
        self.cached = file.load()
    }

    /// 新しい順。
    public var entries: [HistoryEntry] {
        lock.withLock { cached }
    }

    /// - Important: ファイル I/O を同期で行う。発話終了から挿入完了まで 1 秒以内
    ///   （要件定義書 NFR-P6）を守るため、呼び出し側は**挿入を終えたあと**に、
    ///   クリティカルパスの外で呼ぶこと（詳細設計書 §8.2）。
    public func append(_ entry: HistoryEntry) throws {
        try lock.withLock {
            var next = cached
            next.insert(entry, at: 0)
            if next.count > limit { next.removeLast(next.count - limit) }
            try file.save(next)
            cached = next
        }
    }

    /// Undo できる直近の履歴。整形して挿入し、かつ猶予時間内のものだけ。
    ///
    /// 直近が条件を満たさないときに 1 つ前まで遡ることはしない。Undo が戻すのは
    /// 直前に挿入した文字列であって、それ以外を書き換えるとユーザーが見ていない
    /// 箇所を壊すため。
    ///
    /// 猶予は下限も閉じる。`history.json` は手編集でき、システムクロックの巻き戻しも
    /// あるので、未来の日時を許すとその履歴が恒久的に Undo 対象で居座る。
    public func undoCandidate(now: Date = Date()) -> HistoryEntry? {
        guard let latest = entries.first,
              latest.refinedText != nil,
              (0...Self.undoWindow).contains(now.timeIntervalSince(latest.timestamp))
        else { return nil }
        return latest
    }
}
