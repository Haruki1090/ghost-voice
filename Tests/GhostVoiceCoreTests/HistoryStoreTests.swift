import Testing
import Foundation
@testable import GhostVoiceCore

/// 変更通知を記録する。
///
/// **通知はロックの外・書き込みを行ったスレッドから届く**ので、記録側で守る。
private final class ChangeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots: [[HistoryEntry]] = []
    private var deliveredOnMainThread: [Bool] = []

    var record: @Sendable ([HistoryEntry]) -> Void {
        { [self] entries in
            lock.withLock {
                snapshots.append(entries)
                deliveredOnMainThread.append(Thread.isMainThread)
            }
        }
    }

    var count: Int { lock.withLock { snapshots.count } }
    var latest: [HistoryEntry]? { lock.withLock { snapshots.last } }
    var latestRawTexts: [String]? { latest?.map(\.rawText) }
    var everDeliveredOnMainThread: Bool { lock.withLock { deliveredOnMainThread.contains(true) } }
}

/// ストリームの先頭 1 件を期限付きで取る。**期限を切らないと、届かない不具合が停止になる。**
private func firstValue(
    _ stream: AsyncStream<[HistoryEntry]>, timeout: Duration = .seconds(3)
) async -> [HistoryEntry]? {
    await withTaskGroup(of: [HistoryEntry]??.self, returning: [HistoryEntry]?.self) { group in
        group.addTask {
            for await value in stream { return value }
            return [HistoryEntry]?.none
        }
        group.addTask {
            try? await Task.sleep(for: timeout)
            return [HistoryEntry]??.none
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first ?? nil
    }
}

/// `Thread.isMainThread` は async 文脈から直接読めないので、同期の関数へ包む。
@MainActor
private func isOnMainThread() -> Bool { Thread.isMainThread }

/// **MainActor から呼ぶ。** 履歴画面が居る場所と同じ文脈で待つことに意味がある。
@MainActor
private func removeAllFromMainActor(_ store: HistoryStore) async throws {
    #expect(isOnMainThread(), "この検査の前提（MainActor = メインスレッド）が崩れている")
    try await store.removeAll()
}

@Suite("HistoryStore")
struct HistoryStoreTests {

    /// `.iso8601` は秒精度なので、往復して等値を見るテストは整数秒の Date を使う。
    private static let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeEntry(
        raw: String = "生テキスト",
        refined: String? = "整形後テキスト",
        at date: Date = Date()
    ) -> HistoryEntry {
        HistoryEntry(
            id: UUID(), timestamp: date, rawText: raw, refinedText: refined,
            localeIdentifier: "ja-JP", insertionMethod: .ax
        )
    }

    @Test("新しいものが先頭に来る")
    func newestFirst() throws {
        try withTempRoot { root in
            let store = HistoryStore(rootURL: root, limit: 50)
            try store.append(makeEntry(raw: "1つ目"))
            try store.append(makeEntry(raw: "2つ目"))
            #expect(store.entries.map(\.rawText) == ["2つ目", "1つ目"])
        }
    }

    @Test("上限を超えた分は古いものから削除される")
    func trimsToLimit() throws {
        try withTempRoot { root in
            let store = HistoryStore(rootURL: root, limit: 3)
            for i in 1...5 { try store.append(makeEntry(raw: "\(i)")) }
            #expect(store.entries.map(\.rawText) == ["5", "4", "3"])
        }
    }

    /// 上限ちょうどは削らないこと。これが無いと `>` と `>=` の取り違えを見逃す。
    @Test("上限ちょうどの件数は削られない")
    func keepsExactlyLimitEntries() throws {
        try withTempRoot { root in
            let store = HistoryStore(rootURL: root, limit: 3)
            for i in 1...3 { try store.append(makeEntry(raw: "\(i)")) }
            #expect(store.entries.map(\.rawText) == ["3", "2", "1"])
        }
    }

    /// 上限を 1 件超えた時点で削ること。5 件追加してから見る形だと、上限を
    /// 1 件ずらした実装でも最終的に辻褄が合ってしまう（ミューテーション M3）。
    @Test("上限を 1 件超えた時点で削られる")
    func trimsAsSoonAsLimitIsExceeded() throws {
        try withTempRoot { root in
            let store = HistoryStore(rootURL: root, limit: 3)
            for i in 1...4 { try store.append(makeEntry(raw: "\(i)")) }
            #expect(store.entries.map(\.rawText) == ["4", "3", "2"])
        }
    }

    /// `historyLimit` は人が手で編集する設定ファイルから来る（詳細設計書 §9.1）うえ、
    /// `Settings` 側に範囲の検証が無い。負数がそのまま `removeLast` へ渡ると
    /// 「Can't remove more items from a collection than it contains」で落ち、
    /// 発話を失ううえアプリごと巻き添えになる。
    ///
    /// 落ちないことだけでなく、**既定値で動き続けること**を固定する。0 件へ丸めると
    /// 履歴も Undo も挿入失敗時の退避先も無言で失われ、クラッシュと同じものを
    /// 目に見えない形で失う。
    @Test("負の上限は既定値へフォールバックする")
    func fallsBackToDefaultLimitForNegativeLimit() throws {
        try withTempRoot { root in
            let store = HistoryStore(rootURL: root, limit: -1)
            for i in 1...(Settings.default.historyLimit + 1) {
                try store.append(makeEntry(raw: "\(i)"))
            }

            #expect(store.entries.count == Settings.default.historyLimit)
            #expect(store.entries.first?.rawText == "\(Settings.default.historyLimit + 1)")
            #expect(store.undoCandidate() != nil)
        }
    }

    /// 0 は「履歴を残さない」という正当な設定（クランプ無しでも落ちない値）なので、
    /// 既定値へ倒さずそのまま尊重する。
    @Test("上限 0 は尊重され、履歴を持たない")
    func respectsZeroLimit() throws {
        try withTempRoot { root in
            let store = HistoryStore(rootURL: root, limit: 0)
            try store.append(makeEntry(raw: "残らないこと"))

            #expect(store.entries.isEmpty)
            #expect(HistoryStore(rootURL: root, limit: 50).entries.isEmpty)
        }
    }

    @Test("保存した履歴を読み戻せる")
    func persists() throws {
        try withTempRoot { root in
            try HistoryStore(rootURL: root, limit: 50).append(makeEntry(raw: "残る"))
            #expect(HistoryStore(rootURL: root, limit: 50).entries.first?.rawText == "残る")
        }
    }

    /// 挿入経路は V-3 の実地データ、ロケールは再現条件として使う（詳細設計書 §9.3）。
    /// 往復で落ちる項目があると、履歴を残す意味そのものが欠ける。
    ///
    /// 期待値は `HistoryEntry` を通さないリテラルで書く。読み戻した項目どうしを
    /// `==` で比べると、初期化子が項目を握り潰す実装でも期待値が同じように壊れて
    /// 素通りする（ミューテーション M15 / M17 で実際に生き延びた）。
    @Test("読み戻した履歴は全項目と並び順を保つ")
    func persistsAllFieldsAndOrder() throws {
        try withTempRoot { root in
            let oldID = UUID()
            let newID = UUID()
            let newDate = Self.fixedDate.addingTimeInterval(60)
            let store = HistoryStore(rootURL: root, limit: 50)
            try store.append(HistoryEntry(
                id: oldID, timestamp: Self.fixedDate, rawText: "古い生",
                refinedText: nil, localeIdentifier: "en-US", insertionMethod: .clipboardOnly
            ))
            try store.append(HistoryEntry(
                id: newID, timestamp: newDate, rawText: "新しい生",
                refinedText: "新しい整形", localeIdentifier: "ja-JP", insertionMethod: .pasteboard
            ))

            let reloaded = HistoryStore(rootURL: root, limit: 50).entries
            #expect(reloaded.map(\.id) == [newID, oldID])
            #expect(reloaded.map(\.timestamp) == [newDate, Self.fixedDate])
            #expect(reloaded.map(\.rawText) == ["新しい生", "古い生"])
            #expect(reloaded.map(\.refinedText) == ["新しい整形", nil])
            #expect(reloaded.map(\.localeIdentifier) == ["ja-JP", "en-US"])
            #expect(reloaded.map(\.insertionMethod) == [.pasteboard, .clipboardOnly])
        }
    }

    /// 切り詰めがキャッシュ上だけで、ファイルには全件書かれていないこと。
    /// 履歴は 1 MB 以下に収める必要がある（要件定義書 NFR-S2）。
    @Test("切り詰めた結果がファイルにも反映される")
    func persistsTrimmedList() throws {
        try withTempRoot { root in
            let store = HistoryStore(rootURL: root, limit: 2)
            for i in 1...4 { try store.append(makeEntry(raw: "\(i)")) }

            #expect(HistoryStore(rootURL: root, limit: 50).entries.map(\.rawText) == ["4", "3"])
        }
    }

    /// 履歴もユーザーが読める形のファイル（詳細設計書 §9.1）。
    /// これが無いと、上のテスト群は保存先が `history.json` でなくても素通りする。
    @Test("history.json に人間が読める形で書き出す")
    func writesHumanReadableHistoryJSON() throws {
        try withTempRoot { root in
            let store = HistoryStore(rootURL: root, limit: 50)
            try store.append(makeEntry(raw: "生です", refined: "整形です", at: Self.fixedDate))

            let text = try String(
                contentsOf: root.appendingPathComponent("history.json"), encoding: .utf8
            )
            #expect(text.contains("\"rawText\""))
            #expect(text.contains("\"生です\""))
            #expect(text.contains("\"整形です\""))
            #expect(text.contains("2023-11-14T"), "日時が人間に読めない形式になっている")
            #expect(text.contains("\n"), "pretty-printed でないと人間が読み書きできない")
        }
    }

    /// 音声は再現できないので、発話を失わないことが最優先（要件定義書 NFR-V2）。
    /// `HistoryStore` は退避のコードを 1 行も持たないが、init で読むことが前提。
    /// I-4。3 つのストアで同じ契約であることを固定する。
    @Test("復元できなかったときは読み込み失敗を保持する")
    func keepsLoadFailureWhenUnreadable() throws {
        try withTempRoot { root in
            try Data("{ broken".utf8).write(to: root.appendingPathComponent("history.json"))
            #expect(HistoryStore(rootURL: root, limit: 50).loadFailure != nil)
            #expect(HistoryStore(rootURL: root, limit: 50).entries.isEmpty)
        }
    }

    @Test("ファイルが無いだけなら読み込み失敗にしない")
    func absentFileIsNotAFailure() throws {
        try withTempRoot { root in
            #expect(HistoryStore(rootURL: root, limit: 50).loadFailure == nil)
        }
    }

    @Test("復元できなかった履歴は上書きの前に .corrupt へ退避される")
    func quarantinesUnreadableFile() throws {
        try withTempRoot { root in
            let original = "{ this is not json"
            try Data(original.utf8).write(to: root.appendingPathComponent("history.json"))

            let store = HistoryStore(rootURL: root, limit: 50)
            #expect(store.entries.isEmpty)
            try store.append(makeEntry(raw: "新しい発話"))

            let quarantined = root.appendingPathComponent("history.json.corrupt")
            #expect(try String(contentsOf: quarantined, encoding: .utf8) == original)
            #expect(HistoryStore(rootURL: root, limit: 50).entries.map(\.rawText) == ["新しい発話"])
        }
    }

    @Test("10 秒以内に整形挿入した履歴は Undo 対象になる")
    func undoCandidateWithinWindow() throws {
        try withTempRoot { root in
            let store = HistoryStore(rootURL: root, limit: 50)
            let now = Date()
            try store.append(makeEntry(raw: "戻す先", at: now.addingTimeInterval(-5)))

            #expect(store.undoCandidate(now: now)?.rawText == "戻す先")
        }
    }

    /// 猶予ちょうどは受け付けること。これが無いと `<=` と `<` の取り違えを見逃す。
    @Test("ちょうど 10 秒前の履歴は Undo 対象になる")
    func undoCandidateAtWindowBoundary() throws {
        try withTempRoot { root in
            let store = HistoryStore(rootURL: root, limit: 50)
            let now = Date()
            try store.append(makeEntry(at: now.addingTimeInterval(-HistoryStore.undoWindow)))

            #expect(store.undoCandidate(now: now) != nil)
        }
    }

    @Test("10 秒を超えた履歴は Undo 対象にならない")
    func undoCandidateExpires() throws {
        try withTempRoot { root in
            let store = HistoryStore(rootURL: root, limit: 50)
            let now = Date()
            try store.append(makeEntry(at: now.addingTimeInterval(-11)))

            #expect(store.undoCandidate(now: now) == nil)
        }
    }

    @Test("整形していない履歴は Undo 対象にならない")
    func undoCandidateRequiresRefinement() throws {
        try withTempRoot { root in
            let store = HistoryStore(rootURL: root, limit: 50)
            let now = Date()
            try store.append(makeEntry(refined: nil, at: now))

            #expect(store.undoCandidate(now: now) == nil)
        }
    }

    /// 下限は 0 を含むこと。挿入直後に Undo を押した場合、記録時刻と現在時刻は
    /// ほぼ同じになる。上限側の境界テストと対になる。
    @Test("記録時刻ちょうどの履歴は Undo 対象になる")
    func undoCandidateAtSameInstant() throws {
        try withTempRoot { root in
            let store = HistoryStore(rootURL: root, limit: 50)
            let now = Date()
            try store.append(makeEntry(at: now))

            #expect(store.undoCandidate(now: now) != nil)
        }
    }

    /// `history.json` は手編集でき、システムクロックが巻き戻ることもある。猶予に
    /// 下限が無いと、未来の日時を持つ履歴がいつまでも Undo 対象になり続ける。
    @Test("未来の日時を持つ履歴は Undo 対象にならない")
    func undoCandidateRejectsFutureTimestamp() throws {
        try withTempRoot { root in
            let store = HistoryStore(rootURL: root, limit: 50)
            let now = Date()
            try store.append(makeEntry(at: now.addingTimeInterval(60)))

            #expect(store.undoCandidate(now: now) == nil)
        }
    }

    @Test("履歴が空なら Undo 対象は無い")
    func undoCandidateWithoutEntries() throws {
        try withTempRoot { root in
            let store = HistoryStore(rootURL: root, limit: 50)
            #expect(store.undoCandidate(now: Date()) == nil)
        }
    }

    /// Undo が戻すのは直前に挿入した文字列だけ。直近が対象外のときに 1 つ前まで
    /// 遡ると、ユーザーが見ていない箇所の文字列を書き換えることになる。
    @Test("直近が整形なしなら、さらに前の整形済み履歴は Undo 対象にならない")
    func undoCandidateDoesNotLookPastUnrefinedLatest() throws {
        try withTempRoot { root in
            let store = HistoryStore(rootURL: root, limit: 50)
            let now = Date()
            try store.append(makeEntry(raw: "前の発話", refined: "前の整形", at: now))
            try store.append(makeEntry(raw: "直近の発話", refined: nil, at: now))

            #expect(store.undoCandidate(now: now) == nil)
        }
    }

    @Test("直近が猶予切れなら、さらに前の新しい履歴は Undo 対象にならない")
    func undoCandidateDoesNotLookPastExpiredLatest() throws {
        try withTempRoot { root in
            let store = HistoryStore(rootURL: root, limit: 50)
            let now = Date()
            try store.append(makeEntry(raw: "前の発話", at: now))
            try store.append(makeEntry(raw: "直近の発話", at: now.addingTimeInterval(-30)))

            #expect(store.undoCandidate(now: now) == nil)
        }
    }

    // MARK: - 変更通知（欠落 6）

    @Test("append が購読者へ届く")
    func appendNotifiesObserver() throws {
        try withTempRoot { root in
            let store = HistoryStore(rootURL: root, limit: 50)
            let recorder = ChangeRecorder()
            let subscription = store.observe(recorder.record)

            try store.append(makeEntry(raw: "1つ目"))
            try store.append(makeEntry(raw: "2つ目"))

            #expect(recorder.count == 2)
            #expect(recorder.latestRawTexts == ["2つ目", "1つ目"])
            withExtendedLifetime(subscription) {}
        }
    }

    /// **これが欠落 6 の要**。HUD・履歴一覧・設定画面が同時に見るので、
    /// `AsyncStream` のような単一消費者の口では足りない（A-4 の罠）。
    @Test("複数の購読者が同じ変更を受け取る")
    func multipleObserversAllReceiveChanges() throws {
        try withTempRoot { root in
            let store = HistoryStore(rootURL: root, limit: 50)
            let first = ChangeRecorder()
            let second = ChangeRecorder()
            let subscriptions = [store.observe(first.record), store.observe(second.record)]

            try store.append(makeEntry(raw: "両方へ"))

            #expect(first.latestRawTexts == ["両方へ"])
            #expect(second.latestRawTexts == ["両方へ"])
            withExtendedLifetime(subscriptions) {}
        }
    }

    @Test("購読を解除すると通知が止まる")
    func cancelledSubscriptionStopsReceiving() throws {
        try withTempRoot { root in
            let store = HistoryStore(rootURL: root, limit: 50)
            let recorder = ChangeRecorder()
            let subscription = store.observe(recorder.record)

            try store.append(makeEntry(raw: "届く"))
            subscription.cancel()
            try store.append(makeEntry(raw: "届かない"))

            #expect(recorder.count == 1)
            #expect(recorder.latestRawTexts == ["届く"])
        }
    }

    /// **通知はロックの外で配る。** 履歴一覧の再読込は `entries` を読むのが自然なので、
    /// ロックを保持したまま呼ぶと `NSLock` は非再帰なので自己デッドロックする。
    @Test("購読者は通知の中から entries を読める")
    func observerMayReadEntriesFromHandler() throws {
        try withTempRoot { root in
            let store = HistoryStore(rootURL: root, limit: 50)
            let seen = ChangeRecorder()
            let subscription = store.observe { _ in seen.record(store.entries) }

            try store.append(makeEntry(raw: "読み直す"))

            #expect(seen.latestRawTexts == ["読み直す"])
            withExtendedLifetime(subscription) {}
        }
    }

    @Test("changes() は呼ぶたびに独立したストリームを返す")
    func changesReturnsIndependentStreams() async throws {
        try await withTempRoot { root in
            let store = HistoryStore(rootURL: root, limit: 50)
            let first = store.changes()
            let second = store.changes()

            try store.append(makeEntry(raw: "配る"))

            #expect(await firstValue(first)?.map(\.rawText) == ["配る"])
            #expect(await firstValue(second)?.map(\.rawText) == ["配る"])
        }
    }

    // MARK: - 削除と全消去（欠落 7 / FR-9）

    @Test("id を指定して削除でき、ファイルにも反映される")
    func removesEntryByID() async throws {
        try await withTempRoot { root in
            let store = HistoryStore(rootURL: root, limit: 50)
            let doomed = makeEntry(raw: "消す")
            try store.append(makeEntry(raw: "残る"))
            try store.append(doomed)

            #expect(try await store.remove(id: doomed.id))
            #expect(store.entries.map(\.rawText) == ["残る"])
            #expect(HistoryStore(rootURL: root, limit: 50).entries.map(\.rawText) == ["残る"])
        }
    }

    /// 見つからない削除で保存し直すと、壊れたファイルの退避だけが走る等の副作用が出る。
    /// **何も変えないこと**を明示的に固定する。
    @Test("存在しない id の削除は何も変えず false を返す")
    func removingUnknownIDChangesNothing() async throws {
        try await withTempRoot { root in
            let store = HistoryStore(rootURL: root, limit: 50)
            let recorder = ChangeRecorder()
            try store.append(makeEntry(raw: "残る"))
            let subscription = store.observe(recorder.record)

            #expect(try await store.remove(id: UUID()) == false)
            #expect(store.entries.map(\.rawText) == ["残る"])
            #expect(recorder.count == 0, "何も変わっていないのに通知している")
            withExtendedLifetime(subscription) {}
        }
    }

    @Test("複数の id をまとめて削除できる")
    func removesMultipleEntries() async throws {
        try await withTempRoot { root in
            let store = HistoryStore(rootURL: root, limit: 50)
            let a = makeEntry(raw: "a")
            let b = makeEntry(raw: "b")
            let c = makeEntry(raw: "c")
            for entry in [a, b, c] { try store.append(entry) }

            #expect(try await store.remove(ids: [a.id, c.id]) == 2)
            #expect(store.entries.map(\.rawText) == ["b"])
        }
    }

    @Test("全消去できる")
    func removesAllEntries() async throws {
        try await withTempRoot { root in
            let store = HistoryStore(rootURL: root, limit: 50)
            try store.append(makeEntry(raw: "1"))
            try store.append(makeEntry(raw: "2"))

            try await store.removeAll()

            #expect(store.entries.isEmpty)
            #expect(HistoryStore(rootURL: root, limit: 50).entries.isEmpty)
            #expect(store.undoCandidate() == nil, "消したのに Undo 対象が残っている")
        }
    }

    @Test("削除と全消去も購読者へ届く")
    func removalNotifiesObservers() async throws {
        try await withTempRoot { root in
            let store = HistoryStore(rootURL: root, limit: 50)
            let entry = makeEntry(raw: "消す")
            try store.append(entry)
            try store.append(makeEntry(raw: "残る"))

            let recorder = ChangeRecorder()
            let subscription = store.observe(recorder.record)

            _ = try await store.remove(id: entry.id)
            #expect(recorder.latestRawTexts == ["残る"])

            try await store.removeAll()
            #expect(recorder.latestRawTexts == [])
            #expect(recorder.count == 2)
            withExtendedLifetime(subscription) {}
        }
    }

    /// **A-4 の罠をそのまま UI の事故にしないための契約。** 履歴画面は MainActor に居る。
    /// 削除系は同期 I/O を含むので、Core 側が背景へ逃がす。
    @Test("削除系はメインスレッドを塞がない")
    func removalRunsOffTheMainThread() async throws {
        try await withTempRoot { root in
            let store = HistoryStore(rootURL: root, limit: 50)
            try store.append(makeEntry(raw: "消す"))

            let recorder = ChangeRecorder()
            let subscription = store.observe(recorder.record)
            try await removeAllFromMainActor(store)

            #expect(recorder.count == 1)
            #expect(
                !recorder.everDeliveredOnMainThread,
                "同期のファイル I/O がメインスレッドで走っている")
            withExtendedLifetime(subscription) {}
        }
    }

    // MARK: - 上限の実行時変更（欠落 10）

    @Test("上限を下げると即座に切り詰められ、ファイルにも反映される")
    func loweringLimitTrimsImmediately() async throws {
        try await withTempRoot { root in
            let store = HistoryStore(rootURL: root, limit: 50)
            for i in 1...5 { try store.append(makeEntry(raw: "\(i)")) }

            try await store.setLimit(2)

            #expect(store.limit == 2)
            #expect(store.entries.map(\.rawText) == ["5", "4"])
            #expect(HistoryStore(rootURL: root, limit: 50).entries.map(\.rawText) == ["5", "4"])
        }
    }

    @Test("上限を下げたあとの append は新しい上限で切り詰める")
    func appendRespectsUpdatedLimit() async throws {
        try await withTempRoot { root in
            let store = HistoryStore(rootURL: root, limit: 50)
            try await store.setLimit(2)
            for i in 1...4 { try store.append(makeEntry(raw: "\(i)")) }

            #expect(store.entries.map(\.rawText) == ["4", "3"])
        }
    }

    @Test("上限を上げても既存の履歴は消えない")
    func raisingLimitKeepsEntries() async throws {
        try await withTempRoot { root in
            let store = HistoryStore(rootURL: root, limit: 2)
            for i in 1...2 { try store.append(makeEntry(raw: "\(i)")) }

            try await store.setLimit(10)

            #expect(store.limit == 10)
            #expect(store.entries.map(\.rawText) == ["2", "1"])
        }
    }

    /// 切り詰めが起きない上限変更で通知すると、履歴一覧が無駄に再描画される。
    @Test("切り詰めが起きない上限変更では通知しない")
    func limitChangeWithoutTrimDoesNotNotify() async throws {
        try await withTempRoot { root in
            let store = HistoryStore(rootURL: root, limit: 50)
            try store.append(makeEntry(raw: "1"))
            let recorder = ChangeRecorder()
            let subscription = store.observe(recorder.record)

            try await store.setLimit(10)

            #expect(recorder.count == 0)
            withExtendedLifetime(subscription) {}
        }
    }

    /// 負数の扱いは `init` と同じ規則でなければならない。片方だけ直すと、
    /// 設定画面から負数を入れたときにだけ履歴が全部消える、という差が生まれる。
    @Test("負の上限は既定値へフォールバックする（init と同じ規則）")
    func negativeLimitFallsBackToDefault() async throws {
        try await withTempRoot { root in
            let store = HistoryStore(rootURL: root, limit: 50)
            try await store.setLimit(-1)
            #expect(store.limit == Settings.default.historyLimit)
        }
    }

    @Test("上限 0 への変更は尊重され、履歴を空にする")
    func zeroLimitClearsHistory() async throws {
        try await withTempRoot { root in
            let store = HistoryStore(rootURL: root, limit: 50)
            try store.append(makeEntry(raw: "消える"))

            try await store.setLimit(0)

            #expect(store.limit == 0)
            #expect(store.entries.isEmpty)
        }
    }
}

@Suite("HistoryEntry")
struct HistoryEntryTests {

    @Test("整形したときは整形後テキストが挿入された文字列")
    func insertedTextPrefersRefined() {
        let entry = HistoryEntry(
            rawText: "生", refinedText: "整形", localeIdentifier: "ja-JP", insertionMethod: .ax
        )
        #expect(entry.insertedText == "整形")
    }

    @Test("整形しなかったときは生テキストが挿入された文字列")
    func insertedTextFallsBackToRaw() {
        let entry = HistoryEntry(
            rawText: "生", refinedText: nil, localeIdentifier: "ja-JP", insertionMethod: .ax
        )
        #expect(entry.insertedText == "生")
    }
}
