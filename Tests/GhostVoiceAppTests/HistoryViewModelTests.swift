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
            makeHistoryEntry(rawText: "なま", refinedText: "整形済み"), field: .inserted,
            focus: .returned)

        #expect(outcome == .reinserted(.ax))
        #expect(output.insertedTexts == ["整形済み"])
    }

    // MARK: - 前面が戻らなかったとき（待ちの上限に達した場合の振る舞い）

    /// **待ちの上限に達したら、挿入しない。**
    ///
    /// 最前面がまだ Ghost Voice のまま挿入すると、**挿入先が Ghost Voice 自身になる**
    /// （`SystemAccessibility.frontmostProcessIdentifier()` が挿入先を決める）。
    /// そのとき Pasteboard 経路まで落ちると、**⌘V はどこにも刺さらないうえに
    /// 300 ms 後にクリップボードが元へ戻される**——テキストの行き先が 1 つも残らない。
    /// **だから挿入をやめ、代わりにクリップボードへ置く。**
    @Test("前面が戻らなかったら挿入せず、クリップボードへ置く")
    func abandonsReinsertionWhenFocusNeverCameBack() async throws {
        let temp = try SettingsHistoryTempDirectory()
        let output = HistoryTextOutputSpy(outcome: .inserted(.ax))
        let model = HistoryViewModel(
            store: HistoryStore(rootURL: temp.url, limit: 10), output: output)

        let outcome = await model.reinsert(
            makeHistoryEntry(rawText: "なま", refinedText: "整形済み"), field: .inserted,
            focus: .notReturned)

        #expect(outcome == .reinsertAbandoned(copied: true))
        // **1 文字も挿入していない。** ここが要点である。
        #expect(output.insertedTexts.isEmpty, "前面が戻っていないのに挿入している")
        #expect(output.copiedTexts == ["整形済み"])
    }

    /// **どこにあるかを必ず言う。** 「挿入しませんでした」だけでは、
    /// 利用者はテキストが消えたと読む。
    @Test("挿入をやめたときは、テキストがどこにあるかを言う")
    func saysWhereTheTextIsWhenItGivesUp() {
        let copied = HistoryViewModel.ActionOutcome.reinsertAbandoned(copied: true)
        #expect(copied.message.contains("クリップボード"))
        #expect(copied.message.contains("履歴"))
        // クリップボードへ入っており、履歴にも残っている。**失われていないので赤くしない。**
        #expect(copied.isFailure == false)

        let notCopied = HistoryViewModel.ActionOutcome.reinsertAbandoned(copied: false)
        // クリップボードにも入らなかった場合、**残る出口は履歴だけ**である。
        #expect(notCopied.message.contains("履歴"))
        #expect(notCopied.isFailure, "唯一の出口が履歴だけになったことを黙って通している")
    }

    @Test("クリップボードへも置けなければ、そのことも言う")
    func reportsWhenEvenTheClipboardFailed() async throws {
        let temp = try SettingsHistoryTempDirectory()
        let output = HistoryTextOutputSpy(outcome: .inserted(.ax), copySucceeds: false)
        let model = HistoryViewModel(
            store: HistoryStore(rootURL: temp.url, limit: 10), output: output)

        let outcome = await model.reinsert(makeHistoryEntry(), field: .inserted, focus: .notReturned)

        #expect(outcome == .reinsertAbandoned(copied: false))
        #expect(output.insertedTexts.isEmpty)
    }

    @Test("secure input による拒否は、**失敗ではなく拒否として**出す")
    func reinsertRefusalIsNotAFailure() async throws {
        let temp = try SettingsHistoryTempDirectory()
        let output = HistoryTextOutputSpy(outcome: .refusedSecureInput)
        let model = HistoryViewModel(
            store: HistoryStore(rootURL: temp.url, limit: 10), output: output)

        let outcome = await model.reinsert(makeHistoryEntry(), field: .inserted, focus: .returned)

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
        let outcome = await model.reinsert(cancelled, field: .inserted, focus: .returned)

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
