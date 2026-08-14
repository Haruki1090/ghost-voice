import Foundation
import GhostVoiceCore
import Testing

@testable import GhostVoiceApp

/// 履歴画面（FR-9）の振る舞い。
@Suite("履歴画面（FR-9）")
@MainActor
struct HistoryViewModelTests {

    // MARK: - 一覧と購読

    @Test("作った時点で、既にある履歴を持っている")
    func loadsExistingEntries() async throws {
        let temp = try SettingsHistoryTempDirectory()
        let store = HistoryStore(rootURL: temp.url, limit: 10)
        try await appendOffMainActor(makeHistoryEntry(rawText: "一件目"), to: store)

        let model = HistoryViewModel(store: store, output: HistoryTextOutputSpy())
        #expect(model.entries.map(\.rawText) == ["一件目"])
        #expect(model.limit == 10)
    }

    @Test("発話が増えると一覧が追いつく（1 本のストリームを 1 人で読む）")
    func followsChanges() async throws {
        let temp = try SettingsHistoryTempDirectory()
        let store = HistoryStore(rootURL: temp.url, limit: 10)
        let model = HistoryViewModel(store: store, output: HistoryTextOutputSpy())
        model.start()
        defer { model.stop() }

        try await appendOffMainActor(makeHistoryEntry(rawText: "あとから来た"), to: store)

        try await waitUntil { model.entries.first?.rawText == "あとから来た" }
        #expect(model.entries.count == 1)
    }

    @Test("`start()` を 2 回呼んでも購読は 1 本のまま")
    func startIsIdempotent() async throws {
        let temp = try SettingsHistoryTempDirectory()
        let store = HistoryStore(rootURL: temp.url, limit: 10)
        let model = HistoryViewModel(store: store, output: HistoryTextOutputSpy())
        model.start()
        model.start()
        defer { model.stop() }

        try await appendOffMainActor(makeHistoryEntry(rawText: "一度だけ"), to: store)
        try await waitUntil { model.entries.count == 1 }
        #expect(model.entries.map(\.rawText) == ["一度だけ"])
    }

    // MARK: - 挿入経路の集計（`.notInserted` を除く）

    @Test("**中断した発話（`.notInserted`）を経路の分母に入れない**")
    func tallyExcludesNotInserted() throws {
        let entries = [
            makeHistoryEntry(method: .ax),
            makeHistoryEntry(method: .ax),
            makeHistoryEntry(method: .pasteboard),
            makeHistoryEntry(method: .clipboardOnly),
            makeHistoryEntry(method: .notInserted),
            makeHistoryEntry(method: .notInserted),
        ]
        let tally = InsertionMethodTally(entries)

        #expect(tally.ax == 2)
        #expect(tally.pasteboard == 1)
        #expect(tally.clipboardOnly == 1)
        // **6 件あるが分母は 4 件。**
        #expect(tally.insertedTotal == 4)
        // **除いた件数は黙って落とさない。** 落とすと一覧と集計が合わない理由が判らない。
        #expect(tally.notInsertedExcluded == 2)
    }

    @Test("中断した発話だけの履歴では、分母が 0 になる（0 件を「AX 100%」にしない）")
    func tallyOfOnlyCancelledIsEmpty() {
        let tally = InsertionMethodTally([makeHistoryEntry(method: .notInserted)])
        #expect(tally.insertedTotal == 0)
        #expect(tally.notInsertedExcluded == 1)
    }

    // MARK: - コピーと再挿入

    @Test("整形前と挿入したものを、それぞれコピーできる")
    func copiesBothFields() throws {
        let temp = try SettingsHistoryTempDirectory()
        let output = HistoryTextOutputSpy()
        let model = HistoryViewModel(
            store: HistoryStore(rootURL: temp.url, limit: 10), output: output)
        let entry = makeHistoryEntry(rawText: "なま", refinedText: "整形済み")

        #expect(model.copy(entry, field: .raw) == .copied(.raw))
        #expect(model.copy(entry, field: .inserted) == .copied(.inserted))
        #expect(output.copiedTexts == ["なま", "整形済み"])
    }

    @Test("整形されていない発話では、挿入したものは生テキストである")
    func insertedFieldFallsBackToRaw() {
        let entry = makeHistoryEntry(rawText: "なま", refinedText: nil)
        #expect(HistoryTextField.inserted.text(of: entry) == "なま")
    }

    @Test("再挿入は経路を顛末として返す")
    func reinsertReportsMethod() async throws {
        let temp = try SettingsHistoryTempDirectory()
        let output = HistoryTextOutputSpy(outcome: .inserted(.ax))
        let model = HistoryViewModel(
            store: HistoryStore(rootURL: temp.url, limit: 10), output: output)

        let outcome = await model.reinsert(
            makeHistoryEntry(rawText: "なま", refinedText: "整形済み"), field: .inserted)

        #expect(outcome == .reinserted(.ax))
        #expect(output.insertedTexts == ["整形済み"])
    }

    @Test("secure input による拒否は、**失敗ではなく拒否として**出す")
    func reinsertRefusalIsNotAFailure() async throws {
        let temp = try SettingsHistoryTempDirectory()
        let output = HistoryTextOutputSpy(outcome: .refusedSecureInput)
        let model = HistoryViewModel(
            store: HistoryStore(rootURL: temp.url, limit: 10), output: output)

        let outcome = await model.reinsert(makeHistoryEntry(), field: .inserted)

        #expect(outcome == .reinsertRefusedSecureInput)
        #expect(outcome.isFailure == false, "赤く出すと「発話を失った」と読まれる")
        #expect(outcome.message.contains("クリップボードにも残していません"))
    }

    @Test("中断した発話も再挿入できる（**その発話の唯一の出口である**）")
    func cancelledEntryCanBeReinserted() async throws {
        let temp = try SettingsHistoryTempDirectory()
        let output = HistoryTextOutputSpy()
        let model = HistoryViewModel(
            store: HistoryStore(rootURL: temp.url, limit: 10), output: output)

        let cancelled = makeHistoryEntry(
            rawText: "中断した発話", refinedText: nil, method: .notInserted)
        let outcome = await model.reinsert(cancelled, field: .inserted)

        #expect(outcome == .reinserted(.ax))
        #expect(output.insertedTexts == ["中断した発話"])
    }

    // MARK: - 削除

    @Test("1 件消すと一覧からも消える")
    func deletesOne() async throws {
        let temp = try SettingsHistoryTempDirectory()
        let store = HistoryStore(rootURL: temp.url, limit: 10)
        let keep = makeHistoryEntry(rawText: "残す")
        let drop = makeHistoryEntry(rawText: "消す")
        try await appendOffMainActor(keep, to: store)
        try await appendOffMainActor(drop, to: store)

        let model = HistoryViewModel(store: store, output: HistoryTextOutputSpy())
        model.start()
        defer { model.stop() }

        #expect(await model.delete(drop) == .deleted(count: 1))
        try await waitUntil { model.entries.map(\.rawText) == ["残す"] }
    }

    @Test("見つからない項目を消しても、何も起きていないと返る")
    func deletingMissingEntryReportsZero() async throws {
        let temp = try SettingsHistoryTempDirectory()
        let model = HistoryViewModel(
            store: HistoryStore(rootURL: temp.url, limit: 10), output: HistoryTextOutputSpy())
        #expect(await model.delete(makeHistoryEntry()) == .deleted(count: 0))
    }

    @Test("全部消す")
    func deletesAll() async throws {
        let temp = try SettingsHistoryTempDirectory()
        let store = HistoryStore(rootURL: temp.url, limit: 10)
        for index in 0..<3 {
            try await appendOffMainActor(makeHistoryEntry(rawText: "\(index)"), to: store)
        }

        let model = HistoryViewModel(store: store, output: HistoryTextOutputSpy())
        model.start()
        defer { model.stop() }

        #expect(await model.deleteAll() == .deleted(count: 3))
        try await waitUntil { model.entries.isEmpty }
    }

    // MARK: - 読めなかった履歴

    @Test("履歴が読めなかったことは、「まだ喋っていない」と区別して出せる")
    func distinguishesUnreadableFromEmpty() throws {
        let temp = try SettingsHistoryTempDirectory()
        try temp.write("[ 壊れている", to: "history.json")
        let store = HistoryStore(rootURL: temp.url, limit: 10)

        let notices = StoreFileNotice.collect(
            settings: SettingsStore(rootURL: temp.url),
            vocabulary: VocabularyStore(rootURL: temp.url),
            history: store,
            directory: temp.url)
        let model = HistoryViewModel(
            store: store, output: HistoryTextOutputSpy(),
            fileNotice: notices.first { $0.file == .history })

        #expect(model.entries.isEmpty)
        #expect(model.fileNotice != nil, "空の理由が判る")
    }

    // MARK: - 道具

    /// 通知はストアの書き込みスレッドから配られるので、届くのを待つ。
    ///
    /// **時刻の比較で「先に起きたはず」を書かない**（負荷が乗った回に落ちる）。
    /// ここは条件が満たされるまで譲るだけである。
    private func waitUntil(
        _ condition: @MainActor () -> Bool,
        timeout: Duration = .seconds(2),
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("待ち時間を超えても条件が満たされなかった", sourceLocation: sourceLocation)
    }
}
