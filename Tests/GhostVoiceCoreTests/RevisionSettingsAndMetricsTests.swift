import Foundation
import Testing

@testable import GhostVoiceCore

@Suite("差し替えの設定（フェーズ 2）")
struct RevisionSettingsTests {

    @Test("既定は生テキスト先行挿入で、打ち切りは 3 秒")
    func defaults() {
        let settings = Settings.default
        #expect(settings.refinementApplyMode == .afterInsert)
        #expect(settings.revisionDeadlineMs == 3_000)
        #expect(settings.revisionDeadline == .milliseconds(3_000))
    }

    /// **(b) の打ち切りは変えていない。** この値が効く範囲は狭まったが、
    /// (b) の予算計算そのものは裁定の前後で変わらない。
    @Test("(b) の打ち切りは 750 ms のまま")
    func refinementTimeoutIsUnchanged() {
        #expect(Settings.default.refinementTimeoutMs == 750)
    }

    /// **フェーズ 1 が書いた `settings.json` にはこの 2 キーが存在しない。**
    /// 「読めなかった」扱いにすると、更新した利用者の PTT キーもロケールも既定へ戻る。
    @Test("フェーズ 1 の settings.json も読める")
    func readsPhaseOneSettings() throws {
        let json = """
            {"hotkey":{"keyCode":61,"modifiers":["option"]},
             "undoHotkey":{"keyCode":6,"modifiers":["command","control"]},
             "localeIdentifier":"en-US","transcriberKind":"speech",
             "refinementEnabled":false,"refinementTimeoutMs":800,"historyLimit":10}
            """
        let settings = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))

        #expect(settings.localeIdentifier == "en-US", "利用者の設定が既定へ戻っている")
        #expect(settings.refinementTimeoutMs == 800)
        // 省略されたキーは既定値で埋める。
        #expect(settings.refinementApplyMode == .afterInsert)
        #expect(settings.revisionDeadlineMs == 3_000)
    }

    @Test("反映方式と打ち切りは往復して保たれる")
    func roundTrips() throws {
        var settings = Settings.default
        settings.refinementApplyMode = .beforeInsert
        settings.revisionDeadlineMs = 1_500

        let data = try JSONEncoder().encode(settings)
        let restored = try JSONDecoder().decode(Settings.self, from: data)
        #expect(restored == settings)
    }

    @Test("設定ファイルへ保存して読み戻せる")
    func persists() throws {
        try withTempRoot { root in
            let store = SettingsStore(rootURL: root)
            try store.update { $0.refinementApplyMode = .beforeInsert }

            let reloaded = SettingsStore(rootURL: root)
            #expect(reloaded.settings.refinementApplyMode == .beforeInsert)
        }
    }
}

@Suite("Metrics: (a) と (b) で合計の意味が違う")
struct RevisionMetricsTests {

    private func sample(
        finalize: Duration = .milliseconds(100),
        refine: Duration = .milliseconds(700),
        insert: Duration = .milliseconds(30),
        waited: Bool,
        revision: Duration? = nil
    ) -> Metrics.Sample {
        Metrics.Sample(
            finalize: finalize, refine: refine, insert: insert,
            waitedForRefinementBeforeInsert: waited, revision: revision)
    }

    /// (b) は従来どおり `M2 + M3 + M4`。**既存の M5a 実測はこちらの値である。**
    @Test("(b) の合計は M2 + M3 + M4")
    func totalForTheWaitingBranch() {
        let value = sample(waited: true)
        #expect(value.total == .milliseconds(830))
        #expect(value.meetsTarget)
    }

    /// **(a) では整形が挿入の後ろにあるので、合計に入らない。**
    /// これが FR-5(a) の目的そのものである。
    @Test("(a) の合計に整形は入らない")
    func totalForTheRawFirstBranch() {
        let value = sample(waited: false)
        #expect(value.total == .milliseconds(130))
        #expect(value.meetsTarget)
    }

    /// **同じ区間の値でも、経路が違えば合否が変わる。**
    /// 整形が長い発話では (b) が NFR-P6a を破り、(a) は破らない。
    @Test("整形が長い発話は (b) だけが目標を超える")
    func longRefinementOnlyBreaksTheWaitingBranch() {
        let refine = Duration.milliseconds(2_400)
        #expect(sample(refine: refine, waited: true).meetsTarget == false)
        #expect(sample(refine: refine, waited: false).meetsTarget)
    }

    /// **差し替えを行わなかった発話に NFR-P6b の合否は無い。**
    /// nil を「未達」と数えると、差し替えできない挿入先が全部未達に見える。
    @Test("差し替えていない発話に NFR-P6b の合否は無い")
    func revisionTargetIsAbsentWithoutARevision() {
        #expect(sample(waited: false).meetsRevisionTarget == nil)
        #expect(sample(waited: false).revisionMs == nil)
    }

    @Test("NFR-P6b は目標 2 秒で判定する")
    func revisionTarget() {
        #expect(sample(waited: false, revision: .milliseconds(1_900)).meetsRevisionTarget == true)
        #expect(sample(waited: false, revision: .milliseconds(2_100)).meetsRevisionTarget == false)
        #expect(Metrics.revisionBudget == .milliseconds(2_000))
    }

    /// **M2 / M4 は差し替えの後でも動かない。** 挿入までの区間は既に確定している。
    @Test("差し替え後の書き直しは M2 と M4 を動かさない")
    func rewritingKeepsTheInsertionIntervals() {
        let before = sample(refine: .zero, insert: .milliseconds(30), waited: false)
        let after = before.rewriting(refine: .milliseconds(800), revision: .milliseconds(950))

        #expect(after.finalize == before.finalize)
        #expect(after.insert == before.insert)
        #expect(after.refine == .milliseconds(800))
        #expect(after.revision == .milliseconds(950))
        #expect(after.total == before.total, "合計まで動いている")
    }

    /// 合計は 3 つのミリ秒の和ではなく、合計の実時間から丸める。
    @Test("合計は切り捨てを積み上げない")
    func totalRoundsOnce() {
        let value = Metrics.Sample(
            finalize: .microseconds(1_900), refine: .microseconds(1_900),
            insert: .microseconds(1_900), waitedForRefinementBeforeInsert: true)
        #expect(value.finalizeMs == 1)
        #expect(value.totalMs == 5)
    }
}

@Suite("HistoryEntry: Undo の 2 つの述語")
struct HistoryEntryUndoPredicateTests {

    /// `InsertionMethod` は `CaseIterable` ではない（正本の型を検査のために変えない）。
    static let allMethods: [InsertionMethod] = [.ax, .pasteboard, .clipboardOnly, .notInserted]

    private func entry(refined: String?, method: InsertionMethod) -> HistoryEntry {
        HistoryEntry(
            rawText: "生", refinedText: refined, localeIdentifier: "ja-JP",
            insertionMethod: method)
    }

    /// **自動で戻せるのは差し替えできる経路だけである。**
    @Test(
        "自動 Undo の候補は .ax だけ",
        arguments: [
            (InsertionMethod.ax, true),
            (.pasteboard, false),
            (.clipboardOnly, false),
            (.notInserted, false),
        ] as [(InsertionMethod, Bool)]
    )
    func automaticCandidate(method: InsertionMethod, expected: Bool) {
        #expect(entry(refined: "整形", method: method).isAutomaticUndoCandidate == expected)
    }

    /// **ちょうど裏返しの経路を拾う。** 整形結果が入っているのに範囲を持てなかった発話。
    @Test(
        "クリップボードへ取り出す縮退の対象は .pasteboard と .clipboardOnly",
        arguments: [
            (InsertionMethod.ax, false),
            (.pasteboard, true),
            (.clipboardOnly, true),
            (.notInserted, false),
        ] as [(InsertionMethod, Bool)]
    )
    func manualFallbackCandidate(method: InsertionMethod, expected: Bool) {
        #expect(entry(refined: "整形", method: method).isManualUndoFallbackCandidate == expected)
    }

    /// **2 つの述語は決して同時に真にならない。** 同時に真だと、UI が
    /// 「自動で戻す」と「クリップボードへ取り出す」のどちらを出すか決められない。
    @Test("2 つの述語は排他である", arguments: Self.allMethods)
    func predicatesAreDisjoint(method: InsertionMethod) {
        for refined in ["整形", nil] {
            let value = entry(refined: refined, method: method)
            #expect(!(value.isAutomaticUndoCandidate && value.isManualUndoFallbackCandidate))
        }
    }

    @Test("整形していない発話はどちらの候補でもない", arguments: Self.allMethods)
    func unrefinedIsNeither(method: InsertionMethod) {
        let value = entry(refined: nil, method: method)
        #expect(value.isAutomaticUndoCandidate == false)
        #expect(value.isManualUndoFallbackCandidate == false)
    }
}
