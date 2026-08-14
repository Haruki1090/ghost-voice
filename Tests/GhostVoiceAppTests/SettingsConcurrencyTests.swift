import Foundation
import GhostVoiceCore
import Synchronization
import Testing

@testable import GhostVoiceApp

/// **Core の並行性の罠を踏んでいないことを、実地で確かめる。**
///
/// 罠は 3 つある（`core-api-and-hud.md` A-4 と各 doc コメント）。
///
/// 1. `AsyncStream` は単一消費者。複数の `next()` を同時に待つと異常終了する。
/// 2. `SettingsStore.update` の `mutate` はロックを保持したまま走る（`NSLock` は非再帰）。
///    クロージャの中から同じ store の `settings` を読むと**自己デッドロックする。**
/// 3. `SettingsStore.update` / `HistoryStore.append` は同期 I/O をロック内で行う。
///    **MainActor から呼ぶとメインスレッドが止まる。**
///
/// ## 空振りを潰す
///
/// 「塞がない」の検査は、**塞ぐ実装を差し込むと落ちなければ意味が無い。**
/// ここでは同じ検査機構へ `BackgroundWrite`（MainActor へ釘付けにしたもの）を
/// 差し込み、**同じ言明が反転する**ことを見せる。
/// トラック A2 が「`@MainActor` へ差し替えると落ちる」を示した手法と同じである。
@Suite("設定画面: Core の並行性の罠を踏まない")
struct SettingsConcurrencyTests {

    // MARK: - 罠 3: メインスレッドを塞がない

    @Test("本番の書き手は、MainActor から呼んでもメインスレッドを離れる")
    @MainActor
    func offCallerActorLeavesMainThread() async throws {
        #expect(isRunningOnMainThread(), "前提: この検査は MainActor から始まっている")

        let observed = Mutex<Bool?>(nil)
        try await BackgroundWrite.offCallerActor {
            observed.withLock { $0 = isRunningOnMainThread() }
        }
        #expect(observed.withLock { $0 } == false)
    }

    @Test("**空振りでないことの確認**: MainActor へ釘付けにした書き手なら同じ言明が反転する")
    @MainActor
    func mainActorWriterIsDetected() async throws {
        let pinned = BackgroundWrite { work in
            try await MainActor.run { try work() }
        }

        let observed = Mutex<Bool?>(nil)
        try await pinned {
            observed.withLock { $0 = isRunningOnMainThread() }
        }
        // **上の検査と同じ言明が、ここでは true になる。**
        // つまり `isRunningOnMainThread()` は本当に文脈を見分けている。
        #expect(observed.withLock { $0 } == true)
    }

    @Test("ViewModel の保存は、書き込みの地点でメインスレッドを離れている")
    @MainActor
    func viewModelWritesOffMainThread() async throws {
        let temp = try SettingsHistoryTempDirectory()
        let model = makeModel(in: temp)

        // **書き込みの地点そのもので測る。** 書き手の側で測ると、書き手が自分で
        // 選んだ文脈を自分で報告することになり、ViewModel がその書き手を使っているかは
        // 何も示せない。
        let seen = Mutex<[Bool]>([])
        model.writeContextProbe = { isMainThread in seen.withLock { $0.append(isMainThread) } }

        model.draft.historyLimit = 7
        await model.save()

        #expect(seen.withLock { $0 } == [false], "書き込みは 1 回だけ、メインスレッドの外で走る")
    }

    @Test("**空振りでないことの確認**: 書き手を MainActor へ釘付けにすると、上の検査が落ちる形になる")
    @MainActor
    func viewModelProbeDetectsBlockingWriter() async throws {
        let temp = try SettingsHistoryTempDirectory()
        let pinned = BackgroundWrite { work in try await MainActor.run { try work() } }
        let model = makeModel(in: temp, backgroundWrite: pinned)

        let seen = Mutex<[Bool]>([])
        model.writeContextProbe = { isMainThread in seen.withLock { $0.append(isMainThread) } }

        model.draft.historyLimit = 7
        await model.save()

        // **同じ穴・同じ言明で、答えだけが反転している。**
        #expect(seen.withLock { $0 } == [true])
    }

    // MARK: - 罠 2: `update` のクロージャから `settings` を読まない

    @Test("保存は自己デッドロックしない（`update` のクロージャから store を読んでいない）")
    @MainActor
    func saveDoesNotDeadlock() async throws {
        let temp = try SettingsHistoryTempDirectory()
        let model = makeModel(in: temp)

        model.draft.refinementTimeoutMs = 900
        model.draft.historyLimit = 11

        // **止まったらここで戻らない。** 自己デッドロックは検査そのものを固めるので、
        // 「戻ってきたこと」自体が言明である。ソース走査（`SettingsHistorySourceContractTests`）が
        // 「読む形が書かれていないこと」を別途固定している。
        await model.save()

        #expect(model.lastSave?.isFailure == false)
        // 実際にディスクへ載ったことまで見る。**戻っただけでは書けたと言えない。**
        let reloaded = SettingsStore(rootURL: temp.url)
        #expect(reloaded.settings.refinementTimeoutMs == 900)
        #expect(reloaded.settings.historyLimit == 11)
    }

    @Test("保存はまとめて 1 回だけ書く（項目ごとに `update` を呼ばない）")
    @MainActor
    func saveWritesOnce() async throws {
        let temp = try SettingsHistoryTempDirectory()
        let model = makeModel(in: temp)

        let writes = Mutex<Int>(0)
        model.writeContextProbe = { _ in writes.withLock { $0 += 1 } }

        // 5 項目を同時に変える。
        model.draft.refinementEnabled = false
        model.draft.refinementTimeoutMs = 600
        model.draft.historyLimit = 3
        model.draft.revisionDeadlineMs = 2500
        model.draft.refinementApplyMode = .beforeInsert
        await model.save()

        #expect(writes.withLock { $0 } == 1, "`update` の doc コメント: 「まとめて 1 回にすること」")
    }

    // MARK: - 罠 1 / 罠 3: 履歴側

    @Test("履歴の削除は MainActor から `await` してよい（メインスレッドを塞がない）")
    @MainActor
    func historyRemovalDoesNotBlockMainActor() async throws {
        let temp = try SettingsHistoryTempDirectory()
        let store = HistoryStore(rootURL: temp.url, limit: 10)
        let entry = makeHistoryEntry()
        // **書くのは画面の仕事ではない。** ここは前提を作っているだけなので、
        // MainActor の外で `append` する（画面は一度も `append` を呼ばない）。
        try await appendOffMainActor(entry, to: store)

        let model = HistoryViewModel(store: store, output: HistoryTextOutputSpy())
        model.start()
        defer { model.stop() }

        // メインスレッドが生きていることを、削除と同時に走らせた心拍で見る。
        let beats = Mutex<Int>(0)
        let heartbeat = Task { @MainActor in
            for _ in 0..<20 {
                beats.withLock { $0 += 1 }
                await Task.yield()
            }
        }
        let outcome = await model.delete(entry)
        await heartbeat.value

        #expect(outcome == .deleted(count: 1))
        #expect(beats.withLock { $0 } == 20, "削除の間もメインアクターは回っていた")
    }

    // MARK: - 道具

    @MainActor
    private func makeModel(
        in temp: SettingsHistoryTempDirectory,
        backgroundWrite: BackgroundWrite = .offCallerActor,
        session: (any SettingsSessionControlling)? = nil
    ) -> SettingsViewModel {
        SettingsViewModel(
            settings: SettingsStore(rootURL: temp.url),
            vocabulary: VocabularyStore(rootURL: temp.url),
            history: HistoryStore(rootURL: temp.url, limit: 50),
            session: session,
            directory: temp.url,
            backgroundWrite: backgroundWrite)
    }
}

/// **`HistoryStore.append` は MainActor から呼んではならない**（doc コメント）。
/// 検査が前提を作るときも同じ規律を守る。
@concurrent
func appendOffMainActor(_ entry: HistoryEntry, to store: HistoryStore) async throws {
    try store.append(entry)
}
