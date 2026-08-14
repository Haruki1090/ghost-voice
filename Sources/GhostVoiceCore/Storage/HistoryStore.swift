import Foundation

public final class HistoryStore: @unchecked Sendable {
    /// 挿入から Undo を受け付ける時間。これを過ぎるとユーザーが手で
    /// 編集している可能性があるため、無効にする。
    public static let undoWindow: TimeInterval = 10

    private let file: AtomicJSONFile<[HistoryEntry]>
    private let limit: Int
    private let lock = NSLock()
    private var cached: [HistoryEntry]

    /// **読み込みに失敗したか。** ファイルが無い（正常な初回起動）とは区別する。
    ///
    /// 手で編集する JSON がフェーズ 1 の唯一の設定手段なので、カンマ 1 つの打ち間違いで
    /// **全設定が無言で既定へ戻る**（フェーズ 1 の最終レビュー I-4）。利用者から見えるのは
    /// 「`en-US` にしたのに日本語で認識される」で、原因に辿り着く手掛かりが無い。
    /// **保持だけして、表に出すのは CLI の仕事**（`--check` と起動時の 1 行）。
    public let loadFailure: (any Error)?

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
        // **`load()` ではなく `loadOutcome()`。** 「無い」と「読めなかった」を潰さない。
        switch file.loadOutcome() {
        case .loaded(let value):
            self.cached = value
            self.loadFailure = nil
        case .absent:
            self.cached = []
            self.loadFailure = nil
        case .unreadable(let error):
            self.cached = []
            self.loadFailure = error
        }
    }

    /// 新しい順。
    public var entries: [HistoryEntry] {
        lock.withLock { cached }
    }

    /// - Important: ファイル I/O を同期で行う。発話終了からテキストが出るまで 1 秒以内
    ///   （要件定義書 NFR-P6a）を守るため、呼び出し側は**挿入を終えたあと**に、
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

    /// 直近の「整形して挿入し、かつ猶予時間内」の履歴。
    ///
    /// - Important: **これは Undo の門ではない**（要件定義書 FR-7 の細目 / 詳細設計書 §8.3）。
    ///   自動で戻せるのは**差し替えできる経路で挿入した発話**だけで、その門は
    ///   **メモリ上に生きている差し替えハンドル**である。ハンドルは AX 経路でしか作られないので、
    ///   `.pasteboard` / `.clipboardOnly` の発話をここが拾っても戻せない。
    ///   この述語が残るのは履歴 UI（FR-9）が「直近の整形済み発話」を拾うためである。
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
