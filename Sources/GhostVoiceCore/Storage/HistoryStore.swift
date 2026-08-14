import Foundation
import Synchronization

public final class HistoryStore: @unchecked Sendable {
    /// 挿入から Undo を受け付ける時間。これを過ぎるとユーザーが手で
    /// 編集している可能性があるため、無効にする。
    public static let undoWindow: TimeInterval = 10

    /// 変更通知の購読。**手放すと購読も終わる。**
    ///
    /// 画面が消えたのに購読が残ると、解放されない画面のモデルへ通知が届き続ける。
    /// `deinit` で自動的に解除されるので、**画面と同じ寿命の場所へ保持すること。**
    public final class Subscription: Sendable {
        private let unregister: @Sendable () -> Void
        private let cancelled = Atomic<Bool>(false)

        init(unregister: @escaping @Sendable () -> Void) {
            self.unregister = unregister
        }

        /// 明示的に購読をやめる。二度呼んでも安全。
        public func cancel() {
            let (exchanged, _) = cancelled.compareExchange(
                expected: false, desired: true, ordering: .acquiringAndReleasing)
            if exchanged { unregister() }
        }

        deinit { cancel() }
    }

    /// 1 人ぶんの購読者。
    ///
    /// **配った版番号を自分で覚える。** 通知はロックの外で配るので、書き込みが
    /// 別スレッドから重なると新しいスナップショットのあとに古いものが届きうる。
    /// 版番号で落として、**各購読者が受け取る列は必ず単調に新しい**ことを保つ。
    private final class Observer: @unchecked Sendable {
        let id = UUID()
        private let handler: @Sendable ([HistoryEntry]) -> Void
        private let lock = NSLock()
        private var lastDelivered: UInt64 = 0

        init(handler: @escaping @Sendable ([HistoryEntry]) -> Void) {
            self.handler = handler
        }

        func deliver(_ entries: [HistoryEntry], version: UInt64) {
            let shouldDeliver = lock.withLock { () -> Bool in
                guard version > lastDelivered else { return false }
                lastDelivered = version
                return true
            }
            if shouldDeliver { handler(entries) }
        }
    }

    private let file: AtomicJSONFile<[HistoryEntry]>
    private let lock = NSLock()
    private var cached: [HistoryEntry]
    private var storedLimit: Int
    private var observers: [UUID: Observer] = [:]
    /// 配ったスナップショットの版番号。ロックの中でだけ進める。
    private var version: UInt64 = 0

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
        self.storedLimit = Self.normalized(limit)
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

    /// 上限は人が手で編集する設定ファイル由来で、負数が来ても `Settings` は弾かない。
    /// そのまま `removeLast` へ渡すと配列の要素数を超えて落ち、履歴を書く時点では
    /// 発話がもう手元にしか無いので、発話ごと失う。
    ///
    /// 丸め先を 0 にしないのは、0 が「履歴を残さない」という別の指示だから。負数を
    /// そこへ倒すと、打ち間違い 1 文字で履歴も Undo も挿入失敗時の退避先も無言で
    /// 消える（`undoCandidate` は `entries.first` を見るので Undo は恒久的に死ぬ）。
    /// 負数は `-1` を「無制限」と書いた可能性も含めて意図が読めないので、既定値で
    /// 動かす。0 は明示的な指示として尊重する（要素数ぴったりの `removeLast` は
    /// 落ちないので、クランプも要らない）。
    ///
    /// - Important: **`init` と `setLimit(_:)` で同じ規則を使う。** 片方だけ直すと、
    ///   設定画面から負数を入れたときにだけ履歴が全部消える、という差が生まれる。
    private static func normalized(_ limit: Int) -> Int {
        limit < 0 ? Settings.default.historyLimit : limit
    }

    /// 新しい順。
    ///
    /// - Note: MainActor から同期で読んでよい（ロックを取るだけで I/O はしない）。
    public var entries: [HistoryEntry] {
        lock.withLock { cached }
    }

    /// いま効いている保存件数の上限。
    ///
    /// - Note: MainActor から同期で読んでよい。設定画面の表示に使う。
    public var limit: Int {
        lock.withLock { storedLimit }
    }

    // MARK: - 変更通知（複数の画面が同時に購読する）

    /// 履歴が変わるたびに**全件のスナップショット**を受け取る。
    ///
    /// - Important: **単一消費者ではない。** 何人でも同時に購読できる
    ///   （HUD・履歴一覧・設定画面が同時に見る。`AsyncStream` の単一消費者制約とは別物）。
    /// - Important: **ハンドラは MainActor で呼ばれない。** 書き込みを行ったスレッド
    ///   （多くは `DictationSession` の実行スレッド、削除系は背景スレッド）から、
    ///   **ロックを解いた後に**同期で呼ばれる。SwiftUI のモデルを更新するなら
    ///   `Task { @MainActor in … }` で持ち上げること。
    /// - Important: ロックの外で呼ぶので、**ハンドラの中から `entries` や `limit` を
    ///   読んでよい**（`NSLock` は非再帰なので、ロック内で呼んでいたら自己デッドロックする）。
    ///   ただし**ハンドラの中から同じ store を書き換えないこと**（通知が入れ子になる）。
    /// - Important: 各購読者へ届く列は**必ず単調に新しい**。書き込みが重なって
    ///   古いスナップショットが後から回ってきた場合は落とす。
    /// - Returns: 購読。**手放すと購読も終わる**ので、画面と同じ寿命の場所へ保持すること。
    public func observe(
        _ handler: @escaping @Sendable ([HistoryEntry]) -> Void
    ) -> Subscription {
        let observer = Observer(handler: handler)
        lock.withLock { observers[observer.id] = observer }
        return Subscription { [weak self] in
            self?.lock.withLock { _ = self?.observers.removeValue(forKey: observer.id) }
        }
    }

    /// `observe` を `AsyncStream` として使う。
    ///
    /// - Important: **呼ぶたびに独立したストリームを作る。** 画面ごとに 1 本ずつ持てば、
    ///   `AsyncStream` の「複数の `next()` を同時に待つと異常終了する」制約は踏まない。
    ///   **1 本のストリームを 2 箇所で読み回さないこと。**
    /// - Important: 各要素は**その時点の全件**である。読み手が遅れたときは古いものを捨て、
    ///   最新の 1 件だけを残す（スナップショットなので、最新があれば画面は正しく描ける）。
    /// - Note: ストリームの終了（`for await` の離脱・タスクのキャンセル）で購読は自動的に解ける。
    public func changes() -> AsyncStream<[HistoryEntry]> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let subscription = observe { continuation.yield($0) }
            continuation.onTermination = { _ in subscription.cancel() }
        }
    }

    // MARK: - 書き込み

    /// - Important: ファイル I/O を同期で行う。発話終了からテキストが出るまで 1 秒以内
    ///   （要件定義書 NFR-P6a）を守るため、呼び出し側は**挿入を終えたあと**に、
    ///   クリティカルパスの外で呼ぶこと（詳細設計書 §8.2）。
    /// - Important: **MainActor から呼んではならない**（同期の I/O でメインスレッドが止まる）。
    ///   ここは `DictationSession` から呼ばれる口である。UI からの書き込み
    ///   （`remove` / `removeAll` / `setLimit`）は `async` にしてあり、Core 側で背景へ逃がす。
    /// - Returns: **この項目が実際に履歴へ残ったか。**
    ///
    ///   **「例外が出なかったか」ではない。** 上限 0（設定画面のステッパーで到達できる）の
    ///   ときは挿入した項目をその場で捨てるので、書き込みは成功しても**履歴には
    ///   1 件も残らない。** 呼び出し側がこれを「保存された」と読むと、
    ///   **中断された発話が欄にもクリップボードにも履歴にも無いまま、
    ///   失敗を 1 つも出さずに待機へ落ちる**（最終レビュー A-1）。
    @discardableResult
    public func append(_ entry: HistoryEntry) throws -> Bool {
        // 上限 0 のときは挿入した項目をその場で捨てるので、内容は変わらない。
        // それでも保存は行う（フェーズ 1 と同じ挙動。壊れたファイルの退避がここで走る）。
        var retained = false
        try mutate(saveEvenIfUnchanged: true) { entries in
            entries.insert(entry, at: 0)
            if entries.count > storedLimit { entries.removeLast(entries.count - storedLimit) }
            // **ロックの中で読む**（`storedLimit` は `setLimit` が書き換える）。
            retained = storedLimit > 0
            return retained
        }
        return retained
    }

    /// **既に書いた項目へ、後から整形結果を入れる**（FR-5(a) の (a) 分岐）。
    ///
    /// (a) の分岐は 1 発話につき 2 回書く。挿入直後の `append(rawText:refinedText: nil)` と、
    /// 整形が返ってからのこれである。**順序が要件になっている**——詳細設計書 §8.3 は
    /// 「履歴は内容変更より先に確保する。raw と refined の両方が履歴にある状態で
    /// 初めて手順 3 へ進む。書けなければ差し替えを始めない」と定める。
    /// **差し替えの途中で発話が判らなくなる経路（R-9）に対して、履歴が 1 番目の受けである。**
    ///
    /// - Important: **`append` と同じく同期のファイル I/O を行う。MainActor から
    ///   呼んではならない。** ここは `DictationSession` から呼ばれる口である。
    /// - Important: **`rawText` は変えない。** 変えられるのは `refinedText` だけで、
    ///   これは「後から届いた整形結果を足す」以外の用途を持たせないためである
    ///   （履歴の書き換え口を広げると、FR-9 の画面から発話そのものを改変できてしまう）。
    /// - Returns: 更新したか。**見つからなければ何も書かず、通知もしない。**
    ///   古い発話が上限で押し出された後に差し替えが成功した場合がこれに当たる。
    @discardableResult
    public func update(id: HistoryEntry.ID, refinedText: String) throws -> Bool {
        var updated = false
        try mutate { entries in
            guard let index = entries.firstIndex(where: { $0.id == id }) else { return false }
            let old = entries[index]
            guard old.refinedText != refinedText else { return false }
            entries[index] = HistoryEntry(
                id: old.id, timestamp: old.timestamp, rawText: old.rawText,
                refinedText: refinedText, localeIdentifier: old.localeIdentifier,
                insertionMethod: old.insertionMethod
            )
            updated = true
            return true
        }
        return updated
    }

    /// 履歴を 1 件消す（FR-9 の履歴画面から）。
    ///
    /// - Important: **MainActor から `await` してよい。** 同期のファイル I/O を含むが、
    ///   Core 側で呼び出し元の実行文脈を離れて実行する（`@concurrent`）ので、
    ///   メインスレッドは止まらない。
    /// - Returns: 実際に消したか。**見つからなければ何も書かず、通知もしない。**
    @discardableResult
    @concurrent
    public func remove(id: HistoryEntry.ID) async throws -> Bool {
        var removed = false
        try mutate { entries in
            guard let index = entries.firstIndex(where: { $0.id == id }) else { return false }
            entries.remove(at: index)
            removed = true
            return true
        }
        return removed
    }

    /// 履歴をまとめて消す。
    ///
    /// - Important: **MainActor から `await` してよい**（`remove(id:)` と同じ）。
    /// - Returns: 実際に消した件数。0 件なら何も書かず、通知もしない。
    @discardableResult
    @concurrent
    public func remove(ids: Set<HistoryEntry.ID>) async throws -> Int {
        var removed = 0
        try mutate { entries in
            let before = entries.count
            entries.removeAll { ids.contains($0.id) }
            removed = before - entries.count
            return removed > 0
        }
        return removed
    }

    /// 履歴を全部消す。
    ///
    /// - Important: **MainActor から `await` してよい**（`remove(id:)` と同じ）。
    /// - Important: 既に空でもファイルは書き直す（壊れていた `history.json` はここで
    ///   退避され、健全な空の履歴に置き換わる）。**通知は実際に消えたときだけ**行う。
    /// - Important: これを呼ぶと `undoCandidate(now:)` も無くなる。Undo は
    ///   `entries.first` を見るためで、**消したのに戻せる方が危ない。**
    @concurrent
    public func removeAll() async throws {
        try mutate(saveEvenIfUnchanged: true) { entries in
            guard !entries.isEmpty else { return false }
            entries.removeAll()
            return true
        }
    }

    /// 保存件数の上限を実行時に変える（設定画面から。欠落 10）。
    ///
    /// - Important: **MainActor から `await` してよい**（`remove(id:)` と同じ）。
    /// - Important: 下げたときは**その場で切り詰めて保存する。** 次の発話まで
    ///   待つと、設定画面を閉じた時点の表示と実体が食い違う。
    /// - Parameter newLimit: 負数は既定値へ丸める（`init` と同じ規則）。0 は
    ///   「履歴を残さない」という指示として尊重し、既存の履歴も消す。
    @concurrent
    public func setLimit(_ newLimit: Int) async throws {
        let normalized = Self.normalized(newLimit)
        try mutate { entries in
            storedLimit = normalized
            guard entries.count > normalized else { return false }
            entries.removeLast(entries.count - normalized)
            return true
        }
    }

    /// ロックの中で `cached` を作り替え、保存し、**ロックを解いてから**通知する。
    ///
    /// 読み・書き・保存を 1 回のロックで囲む。分けると、2 つの書き込みが重なったときに
    /// 片方の結果が消える（両方が同じ古い配列から作り直す）。
    ///
    /// - Parameter transform: 変更後の配列を作る。**内容が変わったなら true を返す**
    ///   （false なら保存も通知もしない）。
    /// - Parameter saveEvenIfUnchanged: 内容が変わらなくてもファイルへ書くか。
    ///   通知は `transform` が true を返したときだけ行う。
    private func mutate(
        saveEvenIfUnchanged: Bool = false,
        _ transform: (inout [HistoryEntry]) -> Bool
    ) throws {
        lock.lock()
        var next = cached
        let changed = transform(&next)
        guard changed || saveEvenIfUnchanged else {
            lock.unlock()
            return
        }
        do {
            try file.save(next)
        } catch {
            lock.unlock()
            throw error
        }
        var pending: (entries: [HistoryEntry], version: UInt64, observers: [Observer])?
        if changed {
            cached = next
            version &+= 1
            pending = (next, version, Array(observers.values))
        }
        lock.unlock()

        // **ロックの外で配る。** 購読者は通知の中で `entries` を読み直すのが自然で、
        // ロックを保持したまま呼ぶと `NSLock` は非再帰なので自己デッドロックする。
        if let pending {
            for observer in pending.observers {
                observer.deliver(pending.entries, version: pending.version)
            }
        }
    }

    /// 直近の「差し替えできる経路で整形挿入し、かつ猶予時間内」の履歴。
    ///
    /// - Important: **これは Undo の門ではない**（要件定義書 FR-7 の細目 / 詳細設計書 §8.3）。
    ///   自動で戻せるのは**差し替えできる経路で挿入した発話**だけで、その門は
    ///   **メモリ上に生きている `ReplacementAnchor`** である。この述語が残るのは
    ///   履歴 UI（FR-9）が「直近の整形済み発話」を拾うためである。
    ///
    /// - Important: **挿入経路も見る**（持ち越し項目 16。`HistoryEntry.isAutomaticUndoCandidate`）。
    ///   `refinedText != nil` と猶予だけを見ていた頃は、**`.clipboardOnly`——どこにも
    ///   挿入していない発話——がここに載っていた。** そこへ Undo を撃つと、
    ///   挿入していないテキストを消そうとして**別の何かを消す。**
    ///
    /// 直近が条件を満たさないときに 1 つ前まで遡ることはしない。Undo が戻すのは
    /// 直前に挿入した文字列であって、それ以外を書き換えるとユーザーが見ていない
    /// 箇所を壊すため。
    ///
    /// 猶予は下限も閉じる。`history.json` は手編集でき、システムクロックの巻き戻しも
    /// あるので、未来の日時を許すとその履歴が恒久的に Undo 対象で居座る。
    public func undoCandidate(now: Date = Date()) -> HistoryEntry? {
        guard let latest = entries.first,
              latest.isAutomaticUndoCandidate,
              (0...Self.undoWindow).contains(now.timeIntervalSince(latest.timestamp))
        else { return nil }
        return latest
    }
}
