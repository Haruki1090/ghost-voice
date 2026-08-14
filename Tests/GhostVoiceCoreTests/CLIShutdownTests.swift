import Foundation
import Synchronization
import Testing

@testable import GhostVoiceCLI
@testable import GhostVoiceCore

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
    func narrationFeedsWriterAndGate() async {
        let (stream, continuation) = AsyncStream<SessionState>.makeStream()
        let writer = CollectingWriter()
        let gate = ShutdownGate()

        let loop = Task {
            await SessionNarration.consume(stream, metrics: { nil }, writer: writer, gate: gate)
        }
        continuation.yield(.recording(volatileText: "あ"))
        continuation.yield(.finalizing)
        continuation.finish()
        await loop.value

        #expect(writer.text == "\r[録音中] あ\n[確定中]\n")
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
    func shutdownFollowsTheOrder() async {
        let order = CallOrder()
        let gate = ShutdownGate()
        let writer = CollectingWriter()

        await Shutdown.perform(
            gate: gate, grace: .seconds(1),
            stopHotkey: { order.record("stop") },
            awaitRun: {
                order.record("awaitRun.start")
                try? await Task.sleep(for: .milliseconds(100))
                order.record("awaitRun.end")
            },
            finalState: {
                order.record("finalState")
                return .idle
            },
            writer: writer)

        #expect(order.calls == ["stop", "awaitRun.start", "awaitRun.end", "finalState"])
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
                finalState: { await session.state }, writer: writer)

            #expect(inserter.inserted == ["整形後テキストです"])
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
                finalState: { await session.state }, writer: writer)
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
                finalState: { await session.state }, writer: writer)

            #expect(inserter.inserted.isEmpty)
            // **黙って捨ててはならない。** 発話が失われたことを言う。
            #expect(writer.text.contains("挿入されませんでした"))
            await narration.value
        }
    }
}
