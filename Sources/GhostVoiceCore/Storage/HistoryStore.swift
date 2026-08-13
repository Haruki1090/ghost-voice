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
        self.limit = limit
        self.cached = file.load()
    }

    /// 新しい順。
    public var entries: [HistoryEntry] {
        lock.withLock { cached }
    }

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
    public func undoCandidate(now: Date = Date()) -> HistoryEntry? {
        guard let latest = entries.first,
              latest.refinedText != nil,
              now.timeIntervalSince(latest.timestamp) <= Self.undoWindow
        else { return nil }
        return latest
    }
}
