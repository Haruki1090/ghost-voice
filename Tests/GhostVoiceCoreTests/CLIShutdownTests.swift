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

    // MARK: - 端末向けの体裁

    /// **文言は Core が持ち、CLI が足すのは前後の余白だけである。**
    ///
    /// 待ちの案内は `SessionNarration` の進行表示（`\r` で行を上書きする）の途中に
    /// 割り込むので、**必ず行を改めてから出す。** ここが崩れると、
    /// 「PTT キーを離してください」が消しかけの行に重なって読めなくなる。
    @Test("待ちの案内は行を改めてから出し、文言そのものは Core のものを使う")
    func consoleFramesTheAnnouncement() {
        let writer = CollectingWriter()
        let waiting = ShutdownAnnouncement.waiting(grace: .seconds(10))
        writer.announce(waiting)
        #expect(writer.writes == ["\n" + waiting.text + "\n"])

        let other = CollectingWriter()
        other.announce(.finished)
        #expect(other.writes == [ShutdownAnnouncement.finished.text + "\n"])
    }

    // MARK: - 本物の状態機械を通した終了

    private func makeSession(
        root: URL, hotkey: StubHotkeyMonitor, inserter: RecordingInserter,
        transcriber: StubTranscriber
    ) -> DictationSession {
        DictationSession.forTests(
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
                isBusy: { await session.isBusy }, announce: { writer.announce($0) })

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
                isBusy: { await session.isBusy }, announce: { writer.announce($0) })
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
                isBusy: { await session.isBusy }, announce: { writer.announce($0) })
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
                isBusy: { await session.isBusy },
                // **本番と同じ配線で通す**（`GhostVoiceRuntime`）。
                // ここを省くと `isBusy` に落ちるが、救出は `finishIdle()` まで走るので
                // **成功直後の `isBusy` は偽**であり、打ち切ったことすら告げなくなる。
                salvage: { await session.shutdownSalvage },
                announce: { writer.announce($0) })

            #expect(inserter.inserted.isEmpty)
            // **黙って捨ててはならない。** 打ち切った発話がどこに在るかまで言う。
            #expect(writer.text.contains("履歴へ残しました"), "\(writer.text)")
            await narration.value
        }
    }
}
