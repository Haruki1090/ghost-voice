import Foundation
import Synchronization
import Testing

@testable import GhostVoiceCLI
@testable import GhostVoiceCore

/// クロージャをまたいで読み書きする旗。
final class MutableFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Bool
    init(_ value: Bool) { stored = value }
    var value: Bool {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// 書き出された文字列を溜める。
final class CollectingWriter: ConsoleWriting, @unchecked Sendable {
    private let chunks = Mutex<[String]>([])
    var text: String { chunks.withLock { $0.joined() } }
    var writes: [String] { chunks.withLock { $0 } }
    func write(_ text: String) { chunks.withLock { $0.append(text) } }
}

@Suite("CLI: 終了の待ち合わせ")
struct CLIShutdownTests {

    // MARK: - ShutdownGate

    @Test("待機中なら即座に戻る")
    func idleGateReturnsImmediately() async {
        let gate = ShutdownGate()
        #expect(await gate.waitUntilIdle(within: .seconds(5)) == .idle)
    }

    @Test("挿入中なら待機へ戻るまで戻らない")
    func gateWaitsForIdle() async throws {
        let gate = ShutdownGate()
        await gate.observe(.inserting)

        // **「戻っていない」ことを表明する。** ここを書かないと、常に即座に戻る実装でも
        // 検査が通ってしまう（待ち合わせの検査が空虚に真になる典型）。
        let returned = Atomic<Bool>(false)
        let waiter = Task {
            let outcome = await gate.waitUntilIdle(within: .seconds(10))
            returned.store(true, ordering: .relaxed)
            return outcome
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(returned.load(ordering: .relaxed) == false)
        await gate.observe(.idle)
        #expect(await waiter.value == .idle)
    }

    /// `.failed` の直後には必ず `.idle` が続く（`DictationSession` の契約）。
    /// **`.failed` を待機と読み違えると、その直後の後始末を待たずに終わる。**
    @Test("失敗の表示は待機ではない")
    func failedIsNotIdle() async throws {
        let gate = ShutdownGate()
        await gate.observe(.failed(.noSpeechRecognized))
        let returned = Atomic<Bool>(false)
        let waiter = Task {
            let outcome = await gate.waitUntilIdle(within: .seconds(10))
            returned.store(true, ordering: .relaxed)
            return outcome
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(returned.load(ordering: .relaxed) == false)
        await gate.observe(.idle)
        #expect(await waiter.value == .idle)
    }

    @Test("猶予を過ぎたら打ち切って、打ち切ったことを返す")
    func gateTimesOut() async {
        let gate = ShutdownGate()
        await gate.observe(.recording(volatileText: ""))
        let started = ContinuousClock.now
        let outcome = await gate.waitUntilIdle(within: .milliseconds(150))
        let elapsed = ContinuousClock.now - started
        #expect(outcome == .timedOut)
        #expect(elapsed >= .milliseconds(150))
    }

    /// 状態の列が終わった時点で、セッションは処理中の発話を見届けている
    /// （`run()` は `completionTask` を待ってから終端する）。
    @Test("状態の列が終わったら待機とみなす")
    func gateReleasesWhenStreamFinishes() async throws {
        let gate = ShutdownGate()
        await gate.observe(.inserting)
        let waiter = Task { await gate.waitUntilIdle(within: .seconds(10)) }
        try await Task.sleep(for: .milliseconds(50))
        await gate.streamFinished()
        #expect(await waiter.value == .idle)
    }

    // MARK: - 単一の消費者

    @Test("状態の列を読みながら、書き出しと待ち合わせの両方へ配る")
    func narrationFeedsWriterAndGate() async throws {
        let (stream, continuation) = AsyncStream<SessionState>.makeStream()
        let writer = CollectingWriter()
        let gate = ShutdownGate()

        let loop = Task {
            await SessionNarration.consume(stream, metrics: { nil }, writer: writer, gate: gate)
        }
        continuation.yield(.recording(volatileText: "あ"))
        continuation.yield(.finalizing)

        // **門へ配っていることを、終わらせる前に確かめる。** ここを見ないと
        // 「状態を門へ流さない」実装でも通る（列の終端だけで門が開くため）。
        //
        // **固定時間で待たない。** 負荷下で `consume` が間に合わないと偽陽性で落ちる
        // （このプロジェクトが繰り返し踏んできた形）。成立するまで待って、
        // 成立しなければ落ちる形にする。
        try await waitUntil("処理中の状態が門へ届く") {
            await gate.waitUntilIdle(within: .milliseconds(20)) == .timedOut
        }

        continuation.finish()
        await loop.value

        // `\u{1B}[K` は行末までを消す制御（`SessionNarration` の幅合わせ）。
        #expect(writer.text == "\r\u{1B}[K[録音中] あ\n[確定中]\n")
        // 列が終わったので、終了処理は待たされない。
        #expect(await gate.waitUntilIdle(within: .milliseconds(10)) == .idle)
    }

    /// **計測値は待機のときにしか読まない。** 暫定結果のたびに actor を叩くと
    /// 挿入中の状態機械へ余計な往復が乗り、前の発話の値を出す危険もある。
    @Test("計測値は待機のときだけ読む")
    func metricsAreReadOnlyWhenIdle() async {
        let (stream, continuation) = AsyncStream<SessionState>.makeStream()
        let calls = Atomic<Int>(0)
        let writer = CollectingWriter()

        let loop = Task {
            await SessionNarration.consume(
                stream,
                metrics: {
                    calls.add(1, ordering: .relaxed)
                    return Metrics.Sample(
                        finalize: .milliseconds(1), refine: .zero, insert: .zero)
                },
                writer: writer, gate: ShutdownGate())
        }
        continuation.yield(.recording(volatileText: "あ"))
        continuation.yield(.recording(volatileText: "あい"))
        continuation.yield(.inserting)
        continuation.yield(.idle)
        continuation.finish()
        await loop.value

        #expect(calls.load(ordering: .relaxed) == 1)
        #expect(writer.text.contains("[metrics]"))
    }

    /// 順序に意味がある（`Shutdown` の注記）。**待つ → 止める → 見届ける** の順でなければ、
    /// 押しっぱなしのキーの解放が届かなくなったり、挿入の途中で落ちたりする。
    @Test("終了は「待つ・止める・見届ける」の順で行い、見届けを飛ばさない")
    func shutdownFollowsTheOrder() async throws {
        let order = CallOrder()
        let gate = ShutdownGate()
        let writer = CollectingWriter()

        // **門を待機以外にしておく。** 新品の門（＝最初から待機）で測ると
        // `waitUntilIdle` が即座に戻るので、**待ちを止めた後ろへ動かしても順序が変わらない**
        // （この検査だけでは「待つ→止める」を固定できない）。
        await gate.observe(.inserting)
        let release = Task {
            try? await Task.sleep(for: .milliseconds(100))
            order.record("idle")
            await gate.observe(.idle)
        }
        defer { release.cancel() }

        await Shutdown.perform(
            gate: gate, grace: .seconds(5),
            stopHotkey: { order.record("stop") },
            awaitRun: {
                order.record("awaitRun.start")
                try? await Task.sleep(for: .milliseconds(100))
                order.record("awaitRun.end")
            },
            isBusy: {
                order.record("isBusy")
                return false
            },
            writer: writer)

        // **完全一致では固定できない。** 待ちの間に状態機械へ確認する
        // （門は 1 手遅れるため。`Shutdown` の注記）ので `isBusy` は複数回呼ばれる。
        // 固定したいのは**順序の不変条件**である。
        let calls = order.calls
        let idle = try #require(calls.firstIndex(of: "idle"), "待機を観測していない")
        let stop = try #require(calls.firstIndex(of: "stop"), "監視を止めていない")
        let runStart = try #require(calls.firstIndex(of: "awaitRun.start"), "run() を見届けていない")
        let runEnd = try #require(calls.firstIndex(of: "awaitRun.end"))

        #expect(idle < stop, "待機へ戻る前に監視を止めている（押しっぱなしの解放が届かない）")
        #expect(stop < runStart, "監視を止める前に run() を待っている")
        #expect(runStart < runEnd)
        #expect(calls.last == "isBusy", "見届けた後に最終状態を見ていない")
    }

    /// **門は状態機械より 1 手遅れる。**
    ///
    /// 押下の直後に終了要求が来ると、門はまだ「待機」を指している（`.recording` が
    /// まだ配送されていない）。そこで監視を止めると、**キー解放が二度と届かず発話が消える。**
    /// 負荷を掛けた `swift test` で `shutdownWaitsForKeyRelease` が実際に落ちて判った窓。
    @Test("門が待機を指していても、状態機械が処理中なら止めない")
    func waitsWhenGateLagsBehindTheStateMachine() async {
        let gate = ShutdownGate()  // 何も観測していない＝待機を指す
        let writer = CollectingWriter()
        // `Atomic` は ~Copyable でクロージャ内の `#expect` に載せられない。参照型を使う。
        let busy = MutableFlag(true)
        let stopped = MutableFlag(false)

        // 少し遅れて発話が終わる（＝状態機械が待機へ戻る）
        let release = Task {
            try? await Task.sleep(for: .milliseconds(200))
            busy.value = false
        }
        defer { release.cancel() }

        await Shutdown.perform(
            gate: gate, grace: .seconds(5),
            stopHotkey: {
                // **止める瞬間に、状態機械はもう待機でなければならない。**
                #expect(!busy.value, "処理中に監視を止めた（発話が失われる）")
                stopped.value = true
            },
            awaitRun: {},
            isBusy: { busy.value },
            writer: writer)

        #expect(stopped.value)
        #expect(!writer.text.contains("打ち切ります"), "待てるのに打ち切っている")
    }

    // MARK: - 本物の状態機械を通した終了

    private func makeSession(
        root: URL, hotkey: StubHotkeyMonitor, inserter: RecordingInserter,
        transcriber: StubTranscriber
    ) -> DictationSession {
        DictationSession(
            settings: SettingsStore(rootURL: root),
            hotkey: hotkey,
            audio: StubAudioCapture(),
            transcriber: transcriber,
            refiner: SpyRefiner(result: "整形後テキストです"),
            inserter: inserter,
            history: HistoryStore(rootURL: root, limit: 50),
            vocabulary: VocabularyStore(rootURL: root),
            isSecureInputEnabled: { false },
            postEventAuthorization: PostEventAuthorization(probe: { false }),
            finalizeDeadline: .seconds(5)
        )
    }

    /// **これが Task 10 申し送り【1】の本体である。**
    /// 挿入の最中に `exit()` すると、⌘V の送出後・クリップボードの復元前で
    /// プロセスが消えて発話がどこにも残らない。
    @Test("挿入中に終了要求が来たら、挿入が終わってから戻る")
    func shutdownWaitsForInsertionInFlight() async throws {
        try await withTempRoot { root in
            let hotkey = StubHotkeyMonitor()
            let inserter = RecordingInserter(delay: .milliseconds(300))
            let session = makeSession(
                root: root, hotkey: hotkey, inserter: inserter, transcriber: StubTranscriber())
            let gate = ShutdownGate()
            let writer = CollectingWriter()
            let narration = Task {
                await SessionNarration.consume(
                    session.stateUpdates, metrics: { await session.latestMetrics },
                    writer: writer, gate: gate)
            }
            let run = Task { await session.run() }

            hotkey.emit(.pressed)
            try await waitUntil("録音が始まる") {
                if case .recording = await session.state { return true }
                return false
            }
            hotkey.emit(.released)

            await Shutdown.perform(
                gate: gate, grace: .seconds(10),
                stopHotkey: { hotkey.stop() }, awaitRun: { await run.value },
                isBusy: { await session.isBusy }, writer: writer)

            #expect(inserter.inserted == ["整形後テキストです"])
            await narration.value
        }
    }

    /// **押下を受けてから最初の `emit` までの窓。**
    ///
    /// `startRecording()` は `phase = .recording` を立ててから `begin()` と `startTap` を
    /// 待ち、その後で `emit(.recording(...))` する。**その間、`state` は `.idle` のまま**
    /// なので、`state` を見て終了を判断すると「待機だ」と読み違えてホットキーを止め、
    /// **キー解放が二度と届かず発話が丸ごと消える。**
    ///
    /// 窓の長さは `begin()` の費用そのものである（起動後の最初の 1 発話が実測 44〜540 ms
    /// 掛かっていた件は、起動時の捨て往復で吸収した。詳細設計書 §10）。
    /// ここでは代役の `beginDelay` でその窓を作る。
    @Test("押下の直後（最初の状態が出る前）に終了要求が来ても、発話を捨てない")
    func shutdownWaitsDuringTheGapBeforeFirstEmit() async throws {
        try await withTempRoot { root in
            let hotkey = StubHotkeyMonitor()
            let inserter = RecordingInserter()
            let transcriber = StubTranscriber(
                StubTranscriber.Script(beginDelay: .milliseconds(300)))
            let session = makeSession(
                root: root, hotkey: hotkey, inserter: inserter, transcriber: transcriber)
            let gate = ShutdownGate()
            let writer = CollectingWriter()
            let narration = Task {
                await SessionNarration.consume(
                    session.stateUpdates, metrics: { await session.latestMetrics },
                    writer: writer, gate: gate)
            }
            let run = Task { await session.run() }

            hotkey.emit(.pressed)
            // **`begin()` に入った時点で終了要求を出す。** ここは phase だけが立っていて、
            // `state` はまだ `.idle`、門も何も観測していない。
            // **1 回目は起動時の捨て往復**（`warmUpTranscriber()`）。押下で始まるのは 2 回目。
            try await waitUntil("begin() に入る") { transcriber.beginEntered == 2 }
            #expect(await session.state == .idle, "この検査が窓を通っていない（前提が崩れた）")

            let release = Task {
                try? await Task.sleep(for: .milliseconds(400))
                hotkey.emit(.released)
            }
            await Shutdown.perform(
                gate: gate, grace: .seconds(10),
                stopHotkey: { hotkey.stop() }, awaitRun: { await run.value },
                isBusy: { await session.isBusy }, writer: writer)
            await release.value

            #expect(
                inserter.inserted == ["整形後テキストです"],
                "押下直後の窓で監視を止めて、発話を捨てている")
            await narration.value
        }
    }

    /// キーを押したまま Ctrl-C を打った場合。**先に監視を止めると解放が二度と届かず、
    /// その発話はどこにも残らない。** 待ってから止めれば、離した時点で通常どおり流れる。
    @Test("録音中に終了要求が来たら、キーが離されるまで待つ")
    func shutdownWaitsForKeyRelease() async throws {
        try await withTempRoot { root in
            let hotkey = StubHotkeyMonitor()
            let inserter = RecordingInserter()
            let session = makeSession(
                root: root, hotkey: hotkey, inserter: inserter, transcriber: StubTranscriber())
            let gate = ShutdownGate()
            let writer = CollectingWriter()
            let narration = Task {
                await SessionNarration.consume(
                    session.stateUpdates, metrics: { await session.latestMetrics },
                    writer: writer, gate: gate)
            }
            let run = Task { await session.run() }

            hotkey.emit(.pressed)
            try await waitUntil("録音が始まる") {
                if case .recording = await session.state { return true }
                return false
            }

            // 押したまま Ctrl-C。少し遅れてキーが離される。
            let release = Task {
                try? await Task.sleep(for: .milliseconds(200))
                hotkey.emit(.released)
            }
            await Shutdown.perform(
                gate: gate, grace: .seconds(10),
                stopHotkey: { hotkey.stop() }, awaitRun: { await run.value },
                isBusy: { await session.isBusy }, writer: writer)
            await release.value

            #expect(inserter.inserted == ["整形後テキストです"])
            await narration.value
        }
    }

    /// 待ち続けて戻らないのも困る。**猶予で打ち切り、打ち切ったと言う。**
    @Test("キーが離されないまま猶予が尽きたら、その旨を出して終わる")
    func shutdownGivesUpAfterGrace() async throws {
        try await withTempRoot { root in
            let hotkey = StubHotkeyMonitor()
            let inserter = RecordingInserter()
            let session = makeSession(
                root: root, hotkey: hotkey, inserter: inserter, transcriber: StubTranscriber())
            let gate = ShutdownGate()
            let writer = CollectingWriter()
            let narration = Task {
                await SessionNarration.consume(
                    session.stateUpdates, metrics: { await session.latestMetrics },
                    writer: writer, gate: gate)
            }
            let run = Task { await session.run() }

            hotkey.emit(.pressed)
            try await waitUntil("録音が始まる") {
                if case .recording = await session.state { return true }
                return false
            }

            await Shutdown.perform(
                gate: gate, grace: .milliseconds(150),
                stopHotkey: { hotkey.stop() }, awaitRun: { await run.value },
                isBusy: { await session.isBusy }, writer: writer)

            #expect(inserter.inserted.isEmpty)
            // **黙って捨ててはならない。** 発話が失われたことを言う。
            #expect(writer.text.contains("挿入されませんでした"))
            await narration.value
        }
    }
}
